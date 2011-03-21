#! parrot-nqp

pir::load_bytecode("opsc.pbc");
pir::load_bytecode("LLVM.pbc");
pir::load_bytecode("nqp-setting.pbc");
pir::load_bytecode("dumper.pbc");
pir::loadlib("llvm_engine");

Q:PIR { .include "test_more.pir" };

my $pir    := 't/jit/data/03.pir';
my $pbc    := subst($pir, / 'pir' $/, 'pbc');

# Generate PBC file
my @args   := list("./parrot", "-o", $pbc, $pir);
my $res    := pir::spawnw__ip(@args);

# Load PBC into memory
my $handle   := open($pbc, :r, :bin);
my $contents := $handle.readall;
$handle.close();

my $pf := pir::new('Packfile');
$pf.unpack($contents);

ok( 1, "Unpacked" );

my $dir := $pf.get_directory();
ok( pir::defined($dir), "Got PF Directory");

my $bc := $dir{'BYTECODE_' ~ $pir};
ok( pir::defined($bc), "Got bytecode" );

my $opmap := $bc.opmap();
ok( pir::defined($opmap), "Got OpMap");

my $oplib := pir::new__psp("OpLib", "core_ops");

# Parse "jitted.ops"
my $ops_file := Ops::File.new("t/jit/jitted.ops",
    :oplib($oplib),
    :core(0),
    :quiet(0),
);

# Convert it to hash for faster lookup. Also cleanup a bit.
my %parsed_op;
for $ops_file.ops -> $op {
    #$op := Ops::Util::strip_source($op);
    %parsed_op{$op.full_name} := $op;
};

my $trans := Ops::Trans::JIT.new;
ok( 1, "Got Ops::Trans::JIT" );

# JIT context.
my %jit_context := hash(
    level       => 1,
    bc          => $bc,
    trans       => $trans,
    cur_opcode  => 0,
    constants   => $dir{ 'CONSTANT_' ~ $pir },

    basic_blocks => hash(), # offset->basic_block
);
ok( %jit_context, "jit_context" );

# Create few structures. Better to load from compiled bytecode.
my $module  := LLVM::Module.create("foo");
my $builder := LLVM::Builder.create();

my $vtable_struct := LLVM::Type::VTABLE();
$module.add_type_name("struct.VTABLE", $vtable_struct);
ok( 1, "VTABLE" );

#$module.dump();
$module.verify(LLVM::VERIFYER_FAILURE_ACTION::PRINT_MESSAGE);

my $pmc_struct    := LLVM::Type::PMC();
ok( 1, "PMC" );
$module.add_type_name("struct.PMC", $pmc_struct);

#$module.dump();
$module.verify(LLVM::VERIFYER_FAILURE_ACTION::PRINT_MESSAGE);

my $interp_struct := LLVM::Type::struct(
    LLVM::Type::pointer($pmc_struct),    # context
    # All othere fields aren't handled yet
);
ok( 1, "interp_struct" );
$module.add_type_name("struct.parrot_interp_t", $interp_struct);

my $opcode_ptr_type := LLVM::Type::pointer(LLVM::Type::UINTVAL());
ok( 1, "opcode_t *");
$module.add_type_name("opcode_ptr", $opcode_ptr_type);


# Generate JITted function for Sub.
my $jitted_sub := $module.add_function(
    "foo",
    $opcode_ptr_type,
    $opcode_ptr_type,
    LLVM::Type::pointer($interp_struct),
);
%jit_context<jitted_sub> := $jitted_sub;

#$module.dump();

# Handle arguments
my $entry := $jitted_sub.append_basic_block("entry");
# Create explicit return
my $leave := $jitted_sub.append_basic_block("leave");

# TODO Handle args.
$builder.set_position($entry);

my $cur_opcode := $jitted_sub.param(0);
$cur_opcode.name("cur_opcode");
my $cur_opcode_addr := $builder.store(
    $cur_opcode,
    $builder.alloca($cur_opcode.typeof()).name("cur_opcode_addr")
);
%jit_context<cur_opcode_addr> := $cur_opcode_addr;

my $interp     := $jitted_sub.param(1);
$interp.name("interp");
my $interp_addr := $builder.store(
    $interp,
    $builder.alloca($interp.typeof()).name("interp_addr")
);
%jit_context<interp_addr> := $interp_addr;

my $retval := $builder.alloca($opcode_ptr_type).name("retval");
%jit_context<retval> := $retval;


# Create default return.
$builder.set_position($leave);
$builder.ret(
    $builder.load($retval)
);



$module.dump();
#$module.verify(LLVM::VERIFYER_FAILURE_ACTION::PRINT_MESSAGE);

my $total := +$bc;
my $i := 0;

# Enumerate ops and create BasicBlock for each.
while ($i < $total) {
    # Mapped op
    my $id     := $bc[$i];

    # Real opname
    my $opname := $opmap[$id];

    # Get op
    my $op     := $oplib{$opname};

    say("# $opname");
    my $bb := $leave.insert_before("L$i");
    %jit_context<basic_blocks>{$i} := hash(
        label => "L$i",
        bb    => $bb,
    );

    # Next op
    $i := $i + 1 + count_args($op, %jit_context);
}

$module.dump();

# Branch from "entry" BB to next one.
$builder.set_position($entry);
$builder.br($entry.next);

$module.verify(LLVM::VERIFYER_FAILURE_ACTION::PRINT_MESSAGE);

# "JIT" Sub
$i := 0;
while ($i < $total) {
    # Mapped op
    my $id     := $bc[$i];

    # Real opname
    my $opname := $opmap[$id];

    # Get op
    my $op     := $oplib{$opname};
    # Op itself
    say("# $i $opname");

    #_dumper(%parsed_op{ $opname });
    my $parsed_op := %parsed_op{ $opname };
    my $jitted_op := $parsed_op.source( %jit_context );

    %jit_context<basic_blocks>{$i}<body> := $jitted_op;
    #say($jitted_op);

    # Next op
    $i := $i + 1 + count_args($op, %jit_context);
    %jit_context<cur_opcode> := $i;
}

# Dump
for %jit_context<basic_blocks>.keys.sort -> $id {
    my $b := %jit_context<basic_blocks>{$id};
    #print($b<label> ~ ": ");
    #say($b<body>);
}


sub count_args($op, %jit_context) {
    Q:PIR {
        .local pmc op
        .local int s
        find_lex op, '$op'
        s = elements op
        %r = box s
    };

}

# vim: ft=perl6