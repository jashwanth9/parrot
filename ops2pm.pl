#! /usr/bin/perl -w
#
# ops2pm.pl
#
# Generate a Perl module from the operation definitions in an .ops file.
#

use strict;
use lib 'lib';
use Parrot::OpsFile;

use Data::Dumper;
$Data::Dumper::Useqq  = 1;
#$Data::Dumper::Terse  = 1;
#$Data::Dumper::Indent = 0;

sub Usage {
    print STDERR <<_EOF_;
usage: $0 input.ops [input2.ops ...]
_EOF_
    exit;
}


#
# Process command-line argument:
#

Usage() unless @ARGV;

my $file = 'core.ops';

my $base = $file;
$base =~ s/\.ops$//;

my $package = "${base}";
my $moddir  = "lib/Parrot/OpLib";
my $module  = "lib/Parrot/OpLib/${package}.pm";


#
# Read the first input file:
#

use Data::Dumper;

$file = shift @ARGV;
die "$0: Could not read ops file '$file'!\n" unless -e $file;
my $ops = new Parrot::OpsFile $file;

my %seen;
for $file (@ARGV) {
    if ($seen{$file}) {
      print STDERR "$0: Ops file '$file' mentioned more than once!\n";
      next;
    }
    $seen{$file} = 1;

    die "$0: Could not read ops file '$file'!\n" unless -e $file;
    my $temp_ops = new Parrot::OpsFile $file;
    for(@{$temp_ops->{OPS}}) {
       push @{$ops->{OPS}},$_;
    }
}
my $cur_code = 0;
for(@{$ops->{OPS}}) {
    $_->{CODE}=$cur_code++;
}


my $num_ops     = scalar $ops->ops;
my $num_entries = $num_ops + 1; # For trailing NULL


#
# Open the output file:
#

if (! -d $moddir) {
    mkdir($moddir, 0755) or die "$0: Could not mkdir $moddir: $!!\n";
}
open MODULE, ">$module"
  or die "$0: Could not open module file '$module' for writing: $!!\n";


#
# Print the preamble for the MODULE file:
#

my $version = $ops->version;

my $preamble = <<END_C;
#! perl -w
#
# !!!!!!!   DO NOT EDIT THIS FILE   !!!!!!!
#
# This file is generated automatically from '$file'.
# Any changes made here will be lost!
#

use strict;

package Parrot::OpLib::$package;

use vars qw(\$VERSION \$ops);

\$VERSION = "$version";

END_C

print MODULE $preamble;
print MODULE Data::Dumper->Dump([[ $ops->ops ]], [ qw($ops) ]);

print MODULE <<END_C;

1;
END_C

exit 0;

