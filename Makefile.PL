
use ExtUtils::MakeMaker;

# See lib/ExtUtils/MakeMaker.pm for details of how to influence
# the contents of the Makefile that is written.
WriteMakefile (
    NAME         => 'Video::Dumper::QuickTime',
    VERSION_FROM => 'lib/Video/Dumper/QuickTime.pm',         # finds \$VERSION
    AUTHOR       => 'Peter Jaquiery (grandpa@cpan.org)',
    ABSTRACT     => 'Dump QuickTime movie file structure',
    PREREQ_PM    => {
        'Test::More'          => 0.62,
        'Test::Pod::Coverage' => 1.08,
        'Test::Pod'           => 1.26,
        'IO::File'            => 1.13_01,
    },
);
