use Test::More;

eval "use Test::Pod::Coverage 1.00";
plan skip_all => "Test::Pod::Coverage 1.00 required for testing POD coverage"
    if $@;

plan (tests => 1);
pod_coverage_ok(
    "Win32::MSI::HighLevel",
    { also_private => [ qr/^(dump|name)?_/ ], },
    "Win32::MSI::HighLevel, with leading underscore functions as privates\n",
);


