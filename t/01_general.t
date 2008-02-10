use strict;
use warnings;

use Test::More tests => 4;

BEGIN {
    use lib 'lib';    # For development testing

    use_ok ('Video::Dumper::QuickTime');
}

my $object = Video::Dumper::QuickTime->new (-filename => 't/Sample.mov');

isa_ok ($object, 'Video::Dumper::QuickTime');

$object->Dump ();
my $str = $object->Result ();

like ($str, qr/\Q'moov' Movie container @ \E/, 'Has moov atom');
like ($str, qr/\Q'mdat' Media data @ \E/, 'Has mdat atom');
