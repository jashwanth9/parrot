#! perl
# Copyright (C) 2011, Parrot Foundation.

=head1 NAME

src/m0/m0_assembler.pl - M0 Assembler Prototype

=head1 SYNOPSIS

    % m0_assembler.pl foo.m0

=head1 DESCRIPTION

Assembles M0 source code into bytecode which can be run by an M0 interpreter.

=cut

use strict;
use warnings;
use feature 'say';
use autodie qw/:all/;
use File::Slurp qw/slurp write_file/;
use Data::Dumper;
#use Carp::Always;

my $file = shift || die "Usage: $0 foo.m0";
my $file_metadata = {
    total_chunks => 0,
};

my $M0_DIR_SEG      = 0x01;
my $M0_VARS_SEG     = 0x02;
my $M0_META_SEG     = 0x03;
my $M0_BC_SEG       = 0x04;

assemble($file);

sub assemble {
    my ($file) = @_;

    my $ops      = parse_op_data();
    my $source   = slurp($file);
    $source      = remove_junk($source);
    my $version  = parse_version($source);
    my $chunk    = parse_next_chunk($source);
    my $header   = m0b_header();
    my $bytecode = $header . generate_bytecode_for_chunk($ops, $chunk);

    my $bytecode_file = $file . 'b';
    say "Writing bytecode to $bytecode_file";
    write_file $bytecode_file, $bytecode;
}


=item C<m0b_header>

Generate an M0 bytecode header. (Borrowed from t/m0/m0_bytecode_loading.t)

=cut

sub m0b_header {

    #m0b magic number
    my $m0b_header = "\376M0B\r\n\032\n";

    $m0b_header .= pack('C', 0); # version
    $m0b_header .= pack('C', 4); # intval size
    $m0b_header .= pack('C', 8); # floatval size
    $m0b_header .= pack('C', 4); # opcode_t size
    $m0b_header .= pack('C', 4); # void* size
    $m0b_header .= pack('C', 0); # endianness
    $m0b_header .= pack('xx');   # padding

    return $m0b_header;
}

sub parse_op_data {
    my $ops;
    while (<DATA>) {
        chomp;
        my ($num, $name) = split / /, $_;
        $ops->{$name} = $num;
    }
    say "Parsed data for " . scalar(keys %$ops) . " ops";
    return $ops;
}

sub generate_bytecode_for_chunk {
    my ($ops, $chunk) = @_;

    # textual bytecode
    my $tb       = $chunk->{bytecode};
    my $bytecode = '';

    # iterate over textual representation of bytecode
    # use variable table to generate binary bytecode
    my @lines = split /\n/, $tb;
    for my $line (@lines) {
        if ($line =~ m/^(?<opname>[A-z_]+)\s+(?<arg1>\w+)\s*,\s*(?<arg2>\w+)\s*,\s*(?<arg3>\w+)\s*$/) {
            # warn $+{opname} . '=>' . opname_to_num($ops, $+{opname});
            $bytecode = m0b_dir_seg([ $chunk ]);
        } else {
            say "Invalid M0 bytecode segment: $line";
            exit 1;
        }
    }
    return $bytecode;
}

sub m0b_header_length {
    return 8  # magic number
         + 8; # config data
}

=item C<m0b_dir_seg>

Generate a directory for the given set of chunks, assuming that the directory
segment's first byte is at $offset.

=cut

sub m0b_dir_seg {
    my ($chunks) = @_;

    my $offset     = m0b_header_length();
    my $seg_bytes  = pack('L', $M0_DIR_SEG);
    $seg_bytes    .= pack('L', scalar @$chunks);
    $seg_bytes    .= pack('L', m0b_dir_seg_length($chunks));
    $offset       += m0b_dir_seg_length($chunks);

    for (@$chunks) {
        $seg_bytes .= pack('L', $offset);
        $seg_bytes .= pack('L', length($_->{name}));
        $seg_bytes .= $_->{name};
        $offset    += m0b_chunk_length($_);
        #say "offset of next chunk is $offset";
    }

    return $seg_bytes;
}

=item C<m0b_dir_seg_length>

Calculate the number of bytes in a directory segment, using the chunk names in
$chunks.

=cut

sub m0b_dir_seg_length {
    my ($chunks) = @_;

    my $seg_length = 12; # 4 bytes for identifier, 4 for count, 4 for length

    for (@$chunks) {
        $seg_length += 4; # offset into the m0b file
        $seg_length += 4; # size of name
        $seg_length += length($_->{name});
    }

    return $seg_length;
}

=item C<m0b_chunk_length>

Calculate the number of bytes in a chunk.

=cut

sub m0b_chunk_length {
    my ($chunk) = @_;
    my $chunk_length =
           m0b_bc_seg_length($chunk->{bc})
         + m0b_vars_seg_length($chunk->{vars})
         + m0b_meta_seg_length($chunk->{meta});
    #say "chunk length is $chunk_length";
    return $chunk_length;
}

=item C<m0b_bc_seg_length>

Calculate the size of an M0 bytecode segment.

=cut

sub m0b_bc_seg_length {
    my ($size) = @_;

    my $seg_length = 12; # 4 for segment identifier, 4 for count, 4 for size
    $seg_length += $size * 4;

    #say "bytecode seg length is $seg_length";
    return $seg_length;
}

=item C<m0b_vars_seg_length>

Calculate the number of bytes that a variables segment will occupy.

=cut

sub m0b_vars_seg_length {
    my ($vars) = @_;

    my $seg_length = 12; # 4 for segment identifier, 4 for count, 4 for size

    for (@$vars) {
        my $var_length = length($_);
        $seg_length += 4; # storage of size of variable
        $seg_length += length($_);
        #say "after adding var '$_', length is $seg_length";
    }

    #say "vars seg length is $seg_length";
    return $seg_length;
}

=item C<m0b_meta_seg_length>

Calculate the number of bytes that a metadata segment will occupy.

=cut

sub m0b_meta_seg_length {
    my ($metadata) = @_;
    
    my $seg_length = 12; # 4 for segment identifier, 4 for count, 4 for size

    for my $offset (keys %$metadata) {
        for (keys %{$metadata->{$offset}}) {
            $seg_length += 12;
        }
    }

    #say "metadata seg length is $seg_length";
    return $seg_length;
}

sub opname_to_num {
    my ($ops, $opname) = @_;

    return $ops->{$opname};
}

sub parse_version {
    my ($source) = @_;
    if ($source =~ /\.version\s+(?<version>\d+)/) {

    } else {
        say "Invalid M0: No version";
        exit 1;
    }
    say "Parsing M0 v" . $+{version};

    return $+{version};
}

sub parse_next_chunk {
    my ($source) = @_;
    $file_metadata->{total_chunks}++;
    say "Parsing chunk #" . $file_metadata->{total_chunks};

    if ( $source =~ /\.chunk\n\.variables\n(?<variables>.*)\n\.metadata\n(?<metadata>.*)\.bytecode\n(?<bytecode>.*)/ms ) {
        # captures are in %+
    } else {
        print "Invalid M0 at chunk " . $file_metadata->{total_chunks};
        exit 1;
    }
    # force a hash ref via the magic plus
    return +{ %+ };
}

# This cleans M0 code of comments and unnecessary whitespace
sub remove_junk {
    my ($source) = @_;

    # Remove comments and lines that are solely whitespace
    $source =~ s/^(#.*|\s+)$//mg;

    # Remove repeated newlines
    $source =~ s/^\n+//mg;

    return $source;
}

__DATA__
0x00 noop
0x01 goto
0x02 goto_if_eq
0x03 goto_cs
0x04 add_i
0x05 add_n
0x06 sub_i
0x07 sub_n
0x08 mult_i
0x09 mult_n
0x0A div_i
0x0B div_n
0x0C mod_i
0x0D mod_n
0x0E iton
0x0F ntoi
0x10 ashr
0x11 lshr
0x12 shl
0x13 and
0x14 or
0x15 xor
0x16 set
0x17 set_mem
0x18 get_mem
0x19 set_var
0x1A csym
0x1B ccall_arg
0x1C ccall_ret
0x1D ccall
0x1E print_s
0x1F print_i
0x20 print_n
0x21 alloc
0x22 free
0x23 exit
