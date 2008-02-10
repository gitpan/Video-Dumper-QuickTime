package Video::Dumper::QuickTime;
use strict;
use warnings;
use Carp;
use Encode;
use IO::File;

BEGIN {
    use Exporter ();
    use vars qw($VERSION @ISA @EXPORT @EXPORT_OK %EXPORT_TAGS);
    $VERSION     = '1.0000';
    @ISA         = qw(Exporter);
    @EXPORT      = qw();
    @EXPORT_OK   = qw();
    %EXPORT_TAGS = ();
}


=head1 NAME

Video::Dumper::QuickTime - Dump QuickTime movie file structure

=head1 VERSION

Version 1.0000

=head1 SYNOPSIS

    use Video::Dumper::QuickTime;
    my $file = QuickTime->new( -filename => $filename, -progress => \&showProgress );

    eval {$file->Dump ()};
    print "Error during processing: $@\n" if $@;

    my $dumpStr = $file->Result ();

=head1 DESCRIPTION

Video::Dumper::QuickTime parses a QuickTime movie file and generates a
multi-line string describing the structure of the file.

The module is intended primarily as a diagnostic tool, although it would be
possible to subclass Video::Dumper::QuickTime to extract various sections of a
QuickTime file.

=cut

=head3 new

Create a new C<Video::Dumper::QuickTime> instance.

    my $msi = QuickTime->new (-filename => $filename);

=over 4

=item I<-file>: required

the QuickTime movie file to open

=item I<-progress>: optional

reference to a callback sub to display parsing progress.

The progress sub is passed two parameters, the current position and the total
work to be done. A typical callback sub would look like:

    sub showProgress {
        my ( $pos, $total ) = @_;
        ...
    }

=back

=cut

sub new {
    my $proto = shift;
    my $class = ref($proto) || $proto;
    my $self  = bless {}, $class;

    $self = $self->_init(@_);

    return $self;
}

sub _init {
    my $self  = shift;
    my %param = @_;
    $self->_init_attributes(@_);
    $self->{indentStr} ||= '.  ';
    $self->{indent}    ||= '';
    $self->{result}    = '';
    $self->{unknownAtoms} = {};
    return $self;
}

sub _init_attributes {
    my $self = shift;
    my %raw  = @_;
    my %param;

    for ( keys %raw ) {
        /^-?(.+)/;
        $param{$1} = $raw{$_};
    }

    $self->{parsedSize} = 0;
    $self->{progress} = $param{progress} if exists $param{progress};

    my $filename = $param{filename};
    return if !defined $filename;
    $self->{filename} = $filename;
    $self->{filesize} = -s $filename;
    $self->_openFile();
}

sub _openFile {
    my $self = shift;

    $self->{nextUpdate} = $self->{filesize} / 100;

    my $fh = new IO::File;
    $fh->open( $self->{filename} );
    $self->{handle} = $fh;
}

sub _closeFile {
    my $self = shift;
    my $fh   = new IO::File;

    return if !defined $self->{handle};
    $self->{handle}->close();
}

sub read {
    my $self = shift;
    my ( $len, $offset ) = @_;
    my $buf;

    seek $self->{handle}, $offset, 0 if defined $offset;

    my $n = read $self->{handle}, $buf, $len;
    croak 'read failed'          unless defined $n;
    die "end\n" if ! $n;
    croak "short read ($len/$n)" unless $n == $len;

    if ( defined $self->{progress} ) {
        $self->{parsedSize} += $n;

        if ( $self->{nextUpdate} >= $self->{parsedSize} ) {
            $self->{nextUpdate} += $self->{filesize} / 100;
            $self->{progress}->( $self->{parsedSize}, $self->{filesize} );
        }
    }

    return $buf;
}

sub Dump {    # Find top level atoms
    my $self = shift;
    my $pos  = 0;

    eval {
        push @{ $self->{atomStack} }, ( [ 'global', {} ] );
        $pos = $self->describeAtom($pos) while !eof( $self->{handle} );
    };

    $self->_closeFile();

    die $@ if $@ and $@ ne "end\n";
    return $self->{result};
}

sub IndentStr {
    my $self = shift;

    return $self->{indentStr};
}

sub Result {
    my $self = shift;

    return $self->{result};
}

sub append {
    my $self = shift;
    my $lastChar = substr $self->{result}, -1;

    $self->{result} .= $self->{indent} if $lastChar eq "\n";
    $self->{result} .= join '', @_;
}

sub findAtom {
    my ( $self, $attrib, $regexp ) = @_;
    my $limit = @{ $self->{atomStack} };
    my $dataRef;
    my $index = -1;

    while ( -$index < $limit ) {
        $dataRef = \%{ $self->{atomStack}[ $index-- ][1] };
        next if !exists $dataRef->{$attrib};
        last if !defined $regexp;
        last if $dataRef->{$attrib} =~ /$regexp/;
    }

    return $dataRef;
}

sub findAtomValue {
    my ( $self, $attrib, $regexp ) = @_;
    my $dataRef = $self->findAtom( $attrib, $regexp );

    return $dataRef ? $dataRef->{$attrib} : '';
}

sub setParentAttrib {
    my ($self, $attrib, $value) = @_;
    $self->{atomStack}[-2][1]{$attrib} = $value;
}

sub getParentAttribs {
    my ($self) = @_;

    return $self->{atomStack}[-2][1];
}

sub describeAtom {
    my $self = shift;
    my $pos  = shift;
    my ( $len, $key ) = unpack( "Na4", $self->read( 8, $pos ) );

    if ( !defined $len or $len == 0 ) {
        $self->append("End entry\n");
        return $pos + 4;
    }

    $key = 'x' . unpack( 'H8', $key ) if $key =~ /[\x00-\x1f]/;
    $key =~ tr/ /_/;
    $key =~ s/([^\w \d_])/sprintf "%02X", ord ($1)/ge;

    if ( !length $key ) {
        return $pos;
    }

    my $member = "dump_$key";
    my $name   = "name_$key";

    $name = $self->can($name) ? $self->$name() . ' ' : '';

    my $header = sprintf "'%s' %s@ %s (0x%08x) for %s (0x%08x):", $key,
      $name, groupDigits($pos), $pos, groupDigits($len), $len;

    $self->append("$header\n");
    $self->{indent} .= $self->{indentStr};
    if ( $self->can($member) ) {
        push @{ $self->{atomStack} }, [ $key, {} ];
        $self->$member( $pos, $len );
        pop @{ $self->{atomStack} };
    }
    else {
        $self->append( "   Unhandled: length = " . groupDigits($len) . "\n" );
        $self->dumpBlock( $pos + 8, $len > 24 ? 16 : $len - 8 ) if $len > 8;
        if ( !$self->{unknownAtoms}{$key}++ ) {
            printf "Unknown atom '%s' %s (0x%08x) long at %s (0x%08x))\n",
              $key, groupDigits($pos), $pos, groupDigits($len), $len;
        }
    }
    $self->{indent} = substr $self->{indent}, length $self->{indentStr};
    return $pos + $len;
}

sub describeAtoms {
    my $self = shift;
    my ( $pos, $count ) = @_;

    $pos = $self->describeAtom($pos) while $count--;
    return $pos;
}

sub describeAtomsIn {
    my $self = shift;
    my ( $pos, $end ) = @_;

    $pos = $self->describeAtom($pos) while $pos < $end;
}

sub unwrapAtoms {
    my $self = shift;
    my ( $pos, $len ) = @_;

    $self->describeAtomsIn( $pos + 8, $pos + $len );
}

sub atomList {
    my $self = shift;
    my ( $pos, $len ) = @_;

    $self->append( 'Version:  ', unpack( 'C',   $self->read(1) ), "\n" );
    $self->append( 'Flags:    ', unpack( 'B24', $self->read(3) ), "\n" );
    NToSigned( $self->read(4) );
    $self->describeAtomsIn( $pos + 16, $pos + $len );
}

#sub construct_hash {
#    my ($input) = @_;
#    my %hash;
#
#    while ( length($input) > 0 ) {
#        my ($len) = NToSigned( substr( $input, 0, 4, '' ) );
#        my ($cntnt) = substr( $input, 0, $len - 4, '' );
#        my ($type) = substr( $cntnt, 0, 4, '' );
#
#        if ( exists $hash{$type} ) {
#            my @a = grep( $type, keys %hash );
#            $hash{ $type . length(@a) } = $cntnt;
#        }
#        else {
#            $hash{$type} = $cntnt;
#        }
#    }
#    %hash;
#}

sub dump_A9cmt {
    my $self = shift;
    $self->showStr(@_);
}

sub dump_A9cpy {
    my $self = shift;
    $self->showStr(@_);
}

sub dump_A9des {
    my $self = shift;
    $self->showStr(@_);
}

sub dump_A9inf {
    my $self = shift;
    $self->showStr(@_);
}

sub dump_A9nam {
    my $self = shift;
    $self->showStr(@_);
}

sub dump_actn {
    my $self = shift;
    my ( $pos, $len ) = @_;
    my %actionTypes = (
        1  => 'mcActionIdle',
        2  => 'mcActionDraw',
        3  => 'mcActionActivate',
        4  => 'mcActionDeactivate',
        5  => 'mcActionMouseDown',
        6  => 'mcActionKey',
        8  => 'mcActionPlay',
        12 => 'mcActionGoToTime',
        14 => 'mcActionSetVolume',
        15 => 'mcActionGetVolume',
        18 => 'mcActionStep',
        21 => 'mcActionSetLooping',
        22 => 'mcActionGetLooping',
        23 => 'mcActionSetLoopIsPalindrome',
        24 => 'mcActionGetLoopIsPalindrome',
        25 => 'mcActionSetGrowBoxBounds',
        26 => 'mcActionControllerSizeChanged',
        29 => 'mcActionSetSelectionBegin',
        30 => 'mcActionSetSelectionDuration',
        32 => 'mcActionSetKeysEnabled',
        33 => 'mcActionGetKeysEnabled',
        34 => 'mcActionSetPlaySelection',
        35 => 'mcActionGetPlaySelection',
        36 => 'mcActionSetUseBadge',
        37 => 'mcActionGetUseBadge',
        38 => 'mcActionSetFlags',
        39 => 'mcActionGetFlags',
        40 => 'mcActionSetPlayEveryFrame',
        41 => 'mcActionGetPlayEveryFrame',
        42 => 'mcActionGetPlayRate',
        43 => 'mcActionShowBalloon',
        44 => 'mcActionBadgeClick',
        45 => 'mcActionMovieClick',
        46 => 'mcActionSuspend',
        47 => 'mcActionResume',
        48 => 'mcActionSetControllerKeysEnabled',
        49 => 'mcActionGetTimeSliderRect',
        50 => 'mcActionMovieEdited',
        51 => 'mcActionGetDragEnabled',
        52 => 'mcActionSetDragEnabled',
        53 => 'mcActionGetSelectionBegin',
        54 => 'mcActionGetSelectionDuration',
        55 => 'mcActionPrerollAndPlay',
        56 => 'mcActionGetCursorSettingEnabled',
        57 => 'mcActionSetCursorSettingEnabled',
        58 => 'mcActionSetColorTable',
        59 => 'mcActionLinkToURL',
        60 => 'mcActionCustomButtonClick',
        61 => 'mcActionForceTimeTableUpdate',
        62 => 'mcActionSetControllerTimeLimits',
        63 => 'mcActionExecuteAllActionsForQTEvent',
        64 => 'mcActionExecuteOneActionForQTEvent',
        65 => 'mcActionAdjustCursor',
        66 => 'mcActionUseTrackForTimeTable',
        67 => 'mcActionClickAndHoldPoint',
        68 => 'mcActionShowMessageString',
        69 => 'mcActionShowStatusString',
        70 => 'mcActionGetExternalMovie',
        71 => 'mcActionGetChapterTime',
        72 => 'mcActionPerformActionList',
        73 => 'mcActionEvaluateExpression',
        74 => 'mcActionFetchParameterAs',
        75 => 'mcActionGetCursorByID',
        76 => 'mcActionGetNextURL',
        77 => 'mcActionMovieChanged',
        78 => 'mcActionDoScript',
        79 => 'mcActionRestartAtTime',
        80 => 'mcActionGetIndChapter',
        81 => 'mcActionLinkToURLExtended',
    );

    my $type = $actionTypes{ NToSigned( $self->read(4) ) } || 'unknown';
    $self->append("Action type: $type\n");
    $self->append("Reserved\n");
    $self->unwrapAtoms( $pos + 12, $len - 12 );
}

sub name_actn {
    my $self = shift;
    return 'Action';
}

sub dump_alis {
    my $self = shift;
    my ( $pos, $len ) = @_;

    $self->append( 'File #', groupDigits( NToSigned( $self->read(4) ) ), "\n" );
}

sub name_alis {
    my $self = shift;
    return 'File alias';
}

sub dump_clip {
    my $self = shift;
    $self->unwrapAtoms(@_);
}

sub name_clip {
    my $self = shift;
    return 'Clipping region';
}

sub dump_cmov {
    my $self = shift;
    $self->unwrapAtoms(@_);
}

sub name_cmov {
    my $self = shift;
    return 'Compressed movie';
}

sub dump_code {
    my $self = shift;
    my ( $pos, $len ) = @_;

    $self->showUnknown();
    $self->unwrapAtoms( $pos + 12, $len - 12 );
}

sub name_code {
    my $self = shift;
    return 'Code resource';
}

sub dump_data {
    my $self = shift;
    $self->unwrapAtoms(@_);
}

sub name_data {
    my $self = shift;
    return 'Data resource';
}

sub dump_dcom {
    my $self = shift;

    $self->append( 'Compression type: ', $self->get4Char(), "\n" );
}

sub name_dcom {
    my $self = shift;
    return 'Compression type';
}

sub dump_dflt {
    my $self = shift;

    $self->atomList(@_);
}

sub name_dflt {
    my $self = shift;
    return 'Shared frame';
}

sub dump_dinf {
    my $self = shift;

    $self->unwrapAtoms(@_);
}

sub name_dint {
    my $self = shift;
    return 'Media location';
}

sub dump_dref {
    my $self = shift;

    $self->append("\n");
    $self->atomList(@_);
}

sub name_dref {
    my $self = shift;
    return 'Data references';
}

sub dump_edts {
    my $self = shift;
    $self->unwrapAtoms(@_);
}

sub name_edts {
    my $self = shift;
    return "Edit list";
}

sub dump_elst {
    my $self = shift;

    $self->append( 'Version:  ', unpack( 'C',   $self->read(1) ), "\n" );
    $self->append( 'Flags:    ', unpack( 'B24', $self->read(3) ), "\n" );

    my $items = NToSigned( $self->read(4) );
    for ( 1 .. $items ) {
        $self->append("  $_\n");
        my $scale    = $self->findAtomValue('timescale');
        my $duration = NToSigned( $self->read(4) );
        my $durSecs  = $scale ? $duration / $scale : '---';
        $self->append("    Duration: $duration ticks (${durSecs} seconds)\n");
        $self->append( '    Start:    ', NToSigned( $self->read(4) ), "\n" );
        $self->append( '    Rate:     ', NToFixed( $self->read(4) ),  "\n" );
    }
}

sub name_elst {
    my $self = shift;
    return 'Media edit segment defs';
}

sub dump_enfs {
    my $self = shift;
    my ( $pos, $len ) = @_;

    $self->append( 'Enabled: ', cToBool( $self->read(1) ), "\n" );
}

sub name_enfs {
    my $self = shift;
    return 'Enable Frame Stepping';
}

sub dump_evnt {
    my $self = shift;
    my ( $pos, $len ) = @_;

    $self->append( 'Event type:     ', $self->get4Char(), "\n" );

    NToSigned( $self->read(4) );
    $self->append("Reserved\n");
    $self->read(4);
    $self->unwrapAtoms( $pos + 12, $len - 12 );
}

sub name_evnt {
    my $self = shift;
    return 'Sprite event';
}

sub dump_expr {
    my $self = shift;
    my ( $pos, $len ) = @_;

    $self->showUnknown();
    $self->unwrapAtoms( $pos + 12, $len - 12 );
}

sub name_expr {
    my $self = shift;
    return 'Expression';
}

sub dump_free {
    my $self = shift;
    my ( $pos, $len ) = @_;

    $self->append("Padding = $len bytes\n");
    $self->{parsedSize} += $len - 8;
}

sub name_free {
    my $self = shift;
    return 'Unused space';
}

sub dump_ftyp {
    my $self = shift;
    $self->append( unpack( "a4", $self->read(4) ), "\n" );
}

sub name_ftyp {
    my $self = shift;
    return 'File type';
}

sub dump_gmhd {
    my $self = shift;
    $self->unwrapAtoms(@_);
}

sub name_gmhd {
    my $self = shift;
    return 'Generic media header';
}

sub dump_gmin {
    my $self = shift;

    $self->append( 'Version:  ', unpack( 'C',   $self->read(1) ), "\n" );
    $self->append( 'Flags:    ', unpack( 'B24', $self->read(3) ), "\n" );
    $self->showGMode();
    $self->showRGB();
    $self->append( 'Balance:  ', nToSigned( $self->read(2) ), "\n" );
    $self->append("Reserved\n");
    $self->read(2);
}

sub name_gmin {
    my $self = shift;
    return 'Generic media information';
}

sub dump_hdlr {
    my $self    = shift;

    $self->append( 'Version:  ', unpack( 'C',   $self->read(1) ), "\n" );
    $self->append( 'Flags:    ', unpack( 'B24', $self->read(3) ), "\n" );

    my $cmpt = $self->get4Char();
    $self->append( 'Component type:     ', $cmpt, "\n" );

    my $subCmpt = $self->get4Char();
    $self->append( 'Component sub type: ', $subCmpt, "\n" );

    $self->setParentAttrib (HdlrCmpt => $cmpt);
    $self->setParentAttrib (HdlrSubCmpt => $subCmpt);

    $self->append( 'Manufacturer:       ', $self->get4Char(), "\n" );
    $self->append( 'Flags:              ', unpack( 'B32', $self->read(4) ), "\n" );
    $self->append( 'Mask:               ', unpack( 'B32', $self->read(4) ), "\n" );

    my $strLen = ord( $self->read(1) );
    $self->append( 'Name:               ',
        unpack( "a$strLen", $self->read($strLen) ), "\n" );
}

sub name_hdlr {
    my $self = shift;
    return 'Media data handler';
}

sub dump_imag {
    my $self = shift;
    my ( $pos, $len ) = @_;

    $self->showUnknown();
    $self->unwrapAtoms( $pos + 12, $len - 12 );
}

sub name_imag {
    my $self = shift;
    return 'Image';
}

sub dump_imct {
    my $self = shift;
    my ( $pos, $len ) = @_;

    $self->showUnknown();
    $self->unwrapAtoms( $pos + 12, $len - 12 );
}

sub name_imct {
    my $self = shift;
    return 'Image container';
}

sub dump_imda {
    my $self = shift;
    my ( $pos, $len ) = @_;

    $len -= 8;
    $self->append( "Image data " . groupDigits($len) . " bytes long\n" );
    $self->{parsedSize} += $len;
}

sub name_imda {
    my $self = shift;
    return 'Image data';
}

sub dump_imgp {
    my $self = shift;

    $self->unwrapAtoms(@_);
}

sub name_imgp {
    my $self = shift;
    return 'Panorama image container';
}

sub dump_imrg {
    my $self = shift;
    my ( $pos, $len ) = @_;

    $self->showUnknown();
    $self->append( 'X:         ', NToFixed( $self->read(4) ), "\n" );
    $self->append( 'Y:         ', NToFixed( $self->read(4) ), "\n" );
}

sub name_imrg {
    my $self = shift;
    return 'Image group container';
}

sub dump_list {
    my $self = shift;
    my ( $pos, $len ) = @_;

    $self->append( 'Id:    ', NToSigned( $self->read(4) ), "\n" );
    $self->append( 'Items: ', NToSigned( $self->read(4) ), "\n" );
    $self->unwrapAtoms( $pos + 8, $len - 8 );
}

sub name_list {
    my $self = shift;
    return 'List';
}

sub dump_mdat {
    my $self = shift;
    my ( $pos, $len ) = @_;

    $len -= 8;
    $self->append( "Media data " . groupDigits($len) . " bytes long.\n" );
}

sub name_mdat {
    my $self = shift;
    return 'Media data';
}

sub dump_MCPS {
    my $self = shift;
    my ( $pos, $len ) = @_;
    $self->dumpText( $pos + 8, $len - 8 );
}

sub dump_mdhd {
    my $self = shift;

    $self->append( 'Version:  ', unpack( 'C',   $self->read(1) ), "\n" );
    $self->append( 'Flags:    ', unpack( 'B24', $self->read(3) ), "\n" );
    $self->append( 'Creation time:     ', $self->showDate(), "\n" );
    $self->append( 'Modification time: ', $self->showDate(), "\n" );
    my $timescale = NToSigned( $self->read(4) );
    $self->setParentAttrib (timescale => $timescale);
    $self->append("Time scale:        $timescale ticks per second\n");
    my $duration = NToSigned( $self->read(4) );
    my $durSecs  = $duration / $timescale;
    $self->append("Duration:          $duration ticks (${durSecs} seconds)\n");
    $self->append( 'Locale:            ', nToSigned( $self->read(2) ), "\n" );
    $self->append( 'Quality:           ', unpack( 'B16', $self->read(2) ), "\n" );
}

sub name_mdhd {
    my $self = shift;
    return 'Media header';
}

sub dump_mdia {
    my $self = shift;
    $self->unwrapAtoms(@_);
}

sub name_mdia {
    my $self = shift;
    return 'Media container';
}

sub dump_minf {
    my $self = shift;

    $self->unwrapAtoms(@_);
}

sub name_minf {
    my $self = shift;
    return 'Media data';
}

sub dump_mmdr {
    my $self = shift;
    my ( $pos, $len ) = @_;

    $self->showBogus();
    $self->append( 'Unknown:  ', $self->get4Char(), "\n" );
    $self->append( 'Unknown:  ', NToSigned( $self->read(4) ), "\n" );
    $self->unwrapAtoms( $pos + 21, $len - 21 );
}

sub name_mmdr {
    my $self = shift;
    return 'Media data reference';
}

sub dump_moov {
    my $self = shift;

    $self->unwrapAtoms(@_);
}

sub name_moov {
    my $self = shift;
    return 'Movie container';
}

sub dump_motx {
    my $self = shift;
    my ( $pos, $len ) = @_;

    $self->showUnknown();
    $self->append( 'Track index: ', NToSigned( $self->read(4) ), "\n" );
}

sub name_motx {
    my $self = shift;
    return 'Media track index';
}

sub dump_mvhd {
    my $self = shift;
    my ( $pos, $len ) = @_;
    my $buffer = $self->read( $len - 8 );

    $self->append( 'Version:       ',
        unpack( 'C', substr( $buffer, 0, 1, '' ) ) . "\n" );
    $self->append( 'Flags:         ',
        unpack( 'B24', substr( $buffer, 0, 3, '' ) ) . "\n" );
    $self->append( 'Created:       ',
        $self->showDate( substr( $buffer, 0, 4, '' ) ) . "\n" );
    $self->append( 'Modified:      ',
        $self->showDate( substr( $buffer, 0, 4, '' ) ) . "\n" );

    my $timescale = NToSigned( substr( $buffer, 0, 4, '' ) );
    $self->setParentAttrib (timescale => $timescale);
    $self->append("Time scale:    $timescale ticks per second\n");

    my $duration = unpack( "N", substr( $buffer, 0, 4, '' ) );
    my $durSecs = $duration / $timescale;
    $self->append("Duration:      $duration ticks (${durSecs} seconds)\n");
    $self->append( 'Pref rate:     ',
        NToFixed( substr( $buffer, 0, 4, '' ) ) . "\n" );
    $self->append( 'Pref vol:      ',
        unpack( "n", substr( $buffer, 0, 2, '' ) ) . "\n" );
    $self->append("Reserved\n");
    substr $buffer, 0, 10, '';
    $self->append( 'Matrix:        ',
        $self->showMatrix( substr( $buffer, 0, 36, '' ) ) . "\n" );
    $self->append( 'Preview start: ',
        unpack( "N", substr( $buffer, 0, 4, '' ) ) . "\n" );
    $self->append( 'Preview time:  ',
        unpack( "N", substr( $buffer, 0, 4, '' ) ) . "\n" );
    $self->append( 'Poster loc:    ',
        unpack( "N", substr( $buffer, 0, 4, '' ) ) . "\n" );
    $self->append( 'Sel start:     ',
        unpack( "N", substr( $buffer, 0, 4, '' ) ) . "\n" );
    $self->append( 'Sel time:      ',
        unpack( "N", substr( $buffer, 0, 4, '' ) ) . "\n" );
    $self->append( 'Time now:      ',
        unpack( "N", substr( $buffer, 0, 4, '' ) ) . "\n" );
    my $nextTrackId = unpack( "N", substr( $buffer, 0, 4, '' ) );
    $self->append("Next track: $nextTrackId\n");
    $self->{tracks} = $nextTrackId - 1;
}

sub name_mvhd {
    my $self = shift;
    return 'Movie header';
}

sub dump_name {
    my $self = shift;
    my ( $pos, $len ) = @_;
    my $parentType = $self->{atomStack}[-2][0];

    if ( $parentType eq 'imag' ) {
        $self->showUnknown();
        $self->dumpUnicodeText( $pos + 12, $len - 12 );
    }
    else {
        $self->dumpText( $pos + 8, $len - 8 );
    }
}

sub name_name {
    my $self = shift;
    return 'Name';
}

sub dump_oper {
    my $self = shift;
    my ( $pos, $len ) = @_;

    $self->append( 'Operation: ', $self->get4Char(), "\n" );
    $self->append( 'Operands:  ', NToSigned( $self->read(4) ), "\n" );
    $self->append("Reserved\n");
    $self->read(4);
    $self->unwrapAtoms( $pos + 12, $len - 12 );
}

sub name_oper {
    my $self = shift;
    return 'Operation';
}

sub dump_oprn {
    my $self = shift;
    my ( $pos, $len ) = @_;

    $self->showUnknown();
    $self->unwrapAtoms( $pos + 12, $len - 12 );
}

sub name_oprn {
    my $self = shift;
    return 'Operand';
}

sub dump_parm {
    my $self = shift;
    my ( $pos, $len ) = @_;
    my $paramID = NToSigned( $self->read(4) );

    $self->append( 'ID:        ', $paramID,                    "\n" );
    $self->append( 'Unknown 2: ', NToSigned( $self->read(4) ), "\n" );
    $self->append( 'Unknown 3: ', NToSigned( $self->read(4) ), "\n" );

    my $actionStr = $self->findAtomValue('ActionType');
    my $atoms     = qq/
        kActionCase | kActionWhile
        /;
    my $flags = qq/
        kActionMovieSetLoopingFlags
        /;
    my $fixed = qq/
        kActionMovieSetRate | kActionSpriteRotate
        /;
    my $fixedFixedBool = qq/
        kActionSpriteTranslate
        /;
    my $long = qq/
        kActionMovieSetLanguage |
        kActionMovieSetSelection | kActionMovieRestartAtTime |
        kActionQTVRGoToNodeID | kActionMusicPlayNote |
        kActionMusicSetController | kOperandSpriteTrackVariable
        /;
    my $name = qq/
        kActionMovieGoToTimeByName | kActionMovieSetSelectionByName
        /;
    my $quadFloat = qq/
        kActionSpriteTrackSetVariable
        /;
    my $rgnHandle = qq/
        kActionTrackSetClip
        /;
    my $short = qq/
        kActionMovieSetVolume | kActionTrackSetVolume |
        kActionTrackSetBalance | kActionTrackSetLayer |
        kActionSpriteSetImageIndex | kActionSpriteSetVisible |
        kActionSpriteSetLayer
        /;
    my $time = qq/
        kActionMovieGoToTime
        /;

    if ( $actionStr =~ m/$atoms/x ) {
        $self->unwrapAtoms( $pos + 12, $len - 12 );
    }
    elsif ( $actionStr =~ m/$time/x ) {
        $self->unwrapAtoms( $pos + 12, $len - 12 );
    }
    elsif ( $actionStr =~ m/$flags/x ) {
        $self->append( 'Flags: ', NToBin( $self->read(4) ), "\n" );
    }
    elsif ( $actionStr =~ m/$fixed/x ) {
        $self->append( 'Value: ', NToFixed( $self->read(4) ), "\n" );
    }
    elsif ( $actionStr =~ m/$fixedFixedBool/x ) {
        $self->append( 'Value 1:    ', NToFixed( $self->read(4) ), "\n" );
        $self->append( 'Value 2:    ', NToFixed( $self->read(4) ), "\n" );
        $self->append( 'Bool value: ', cToBool( $self->read(1) ),  "\n" );
    }
    elsif ( $actionStr =~ m/$long/x ) {
        $self->append( 'Value: ', groupDigits( NToSigned( $self->read(4) ) ),
            "\n" );
    }
    elsif ( $actionStr =~ m/$name/x ) {
        $self->dumpText( $pos + 12, $len - 12 );
    }
    elsif ( $actionStr =~ m/$quadFloat/x ) {
        if ( $paramID == 1 ) {
            $self->append( 'ID: ', NToSigned( $self->read(4) ), "\n" );
        }
        else {
            $self->append( 'value: ', $self->fToFloat( $self->read(4) ), "\n" );
        }
    }
    elsif ( $actionStr =~ m/$rgnHandle/x ) {
        $self->append( 'Size:   ', nToSigned( $self->read(2) ), "\n" );
        $self->append( 'Top:    ', nToSigned( $self->read(2) ), "\n" );
        $self->append( 'Left:   ', nToSigned( $self->read(2) ), "\n" );
        $self->append( 'Bottom: ', nToSigned( $self->read(2) ), "\n" );
        $self->append( 'Right:  ', nToSigned( $self->read(2) ), "\n" );
    }
    elsif ( $actionStr =~ m/$short/x ) {
        $self->append( 'Value: ', nToSigned( $self->read(2) ), "\n" );
    }
    else {
        $self->append("Unhandled parameter for action: $actionStr\n");
        print "Unhandled parameter for action: $actionStr\n";
    }
}

sub name_parm {
    my $self = shift;
    return 'Parameter';
}

sub dump_play {
    my $self = shift;
    my ( $pos, $len ) = @_;

    $self->append( 'Enabled: ', cToBool( $self->read(1) ), "\n" );
}

sub name_play {
    my $self = shift;
    return 'Auto play';
}

sub dump_sean {
    my $self = shift;
    my ( $pos, $len ) = @_;
    my $end = $pos + $len;

    $pos += 20;
    $self->describeAtomsIn( $pos, $end );
}

sub name_sean {
    my $self = shift;
    return 'Sprite scene container';
}

sub dump_slau {
    my $self = shift;
    my ( $pos, $len ) = @_;

    $self->append( 'Enabled: ', cToBool( $self->read(1) ), "\n" );
}

sub name_slau {
    my $self = shift;
    return 'Slave audio';
}

sub dump_slgr {
    my $self = shift;
    my ( $pos, $len ) = @_;

    $self->append( 'Enabled: ', cToBool( $self->read(1) ), "\n" );
}

sub name_slgr {
    my $self = shift;
    return 'Slave graphics mode';
}

sub dump_slti {
    my $self = shift;
    my ( $pos, $len ) = @_;

    $self->append( 'Enabled: ', cToBool( $self->read(1) ), "\n" );
}

sub name_slti {
    my $self = shift;
    return 'Slave time';
}

sub dump_sltr {
    my $self = shift;
    my ( $pos, $len ) = @_;

    $self->append( 'Enabled: ', cToBool( $self->read(1) ), "\n" );
}

sub name_sltr {
    my $self = shift;
    return 'Slave track duration';
}

sub dump_spid {
    my $self = shift;

    $self->showUnknown();
    $self->append( 'Sprite id: ', NToSigned( $self->read(4) ), "\n" );
}

sub name_spid {
    my $self = shift;
    return 'Sprite ID';
}

sub dump_stbl {
    my $self = shift;

    $self->unwrapAtoms(@_);
}

sub name_stbl {
    my $self = shift;
    return 'Media time to sample data';
}

sub dump_stco {
    my $self = shift;
    my ( $pos, $len ) = @_;
    my $dataRef = $self->findAtom( 'HdlrSubCmpt', '^(?!alis)' );

    $self->append( 'Version:  ', unpack( 'C',   $self->read(1) ), "\n" );
    $self->append( 'Flags:    ', unpack( 'B24', $self->read(3) ), "\n" );

    my $entries = NToSigned( $self->read(4) );
    my $digits  = length $entries;
    my $type    = ( defined $dataRef && $dataRef->{'HdlrSubCmpt'} ) || '';
    $pos += 16;

    for ( 1 .. $entries ) {
        my $off = NToSigned( $self->read( 4, $pos ) );
        $pos += 4;
        $self->append( sprintf( "  %*d ", $digits, $_ ) );
        $self->append( "$type @ ", sprintf "%d (0x%04x)\n", $off, $off );
        if ( $type =~ /sprt|moov/ ) {
            $self->describeAtom( $off + 12 );
        }
        elsif ( $type eq 'vide' ) {
            $self->append("    Not expanded\n");
        }
        else {
            print "stco doesn't handle $type chunks\n";
            next;
        }
    }
}

sub name_stco {
    my $self = shift;
    return 'Media data chunk locations';
}

sub dump_sprt {
    my $self = shift;

    $self->atomList(@_);
}

sub name_sprt {
    my $self = shift;
    return 'Sprite key frame';
}

sub dump_stsc {
    my $self = shift;
    my ( $pos, $len ) = @_;

    $self->append( 'Version:  ', unpack( 'C',   $self->read(1) ), "\n" );
    $self->append( 'Flags:    ', unpack( 'B24', $self->read(3) ), "\n" );
    my $entries = NToSigned( $self->read(4) );
    my $digits  = length $entries;

    for ( 1 .. $entries ) {
        $self->append( sprintf( "  %*d\n", $digits, $_ ) );
        $self->append( '    first chunk: ',    NToSigned( $self->read(4) ), "\n" );
        $self->append( '    samp per chunk: ', NToSigned( $self->read(4) ), "\n" );
        $self->append( '    samp desc id:   ', NToSigned( $self->read(4) ), "\n" );
    }
}

sub name_stsc {
    my $self = shift;
    return 'Sample number to chunk number mapping';
}

sub dump_stsd {
    my $self = shift;
    my ( $pos, $len ) = @_;

    $self->append( 'Version:  ', unpack( 'C',   $self->read(1) ), "\n" );
    $self->append( 'Flags:    ', unpack( 'B24', $self->read(3) ), "\n" );
    my $entries = NToSigned( $self->read(4) );
    my $digits  = length $entries;

    for ( 1 .. $entries ) {
        $self->append( sprintf( "  %*d\n", $digits, $_ ) );
        NToSigned( $self->read(4) );
        $self->append( '    format:  ', $self->get4Char(), "\n" );
        $self->append("    Reserved\n");
        NToSigned( $self->read(6) );
        $self->append( '    index:   ', nToSigned( $self->read(2) ), "\n" );
    }
}

sub name_stsd {
    my $self = shift;
    return 'Sample description container';
}

sub dump_stsh {
    my $self = shift;

    $self->append( 'Version: ', unpack( 'C',   $self->read(1) ), "\n" );
    $self->append( 'Flags:   ', unpack( 'B24', $self->read(3) ), "\n" );
    my $entries = NToSigned( $self->read(4) );
    my $digits  = length $entries;

    for ( 1 .. $entries ) {
        $self->append( sprintf( "%*d ", $digits, $_ ) );
        $self->append( 'frame diff samp # ', NToSigned( $self->read(4) ) );
        $self->append( ' => sync samp # ', NToSigned( $self->read(4) ), "\n" );
    }
}

sub name_stsh {
    my $self = shift;
    return 'Shadow sync table';
}

sub dump_stsz {
    my $self = shift;

    $self->append( 'Version: ', unpack( 'C',   $self->read(1) ), "\n" );
    $self->append( 'Flags:   ', unpack( 'B24', $self->read(3) ), "\n" );

    my $sampleSize = NToSigned( $self->read(4) );
    my $entries    = NToSigned( $self->read(4) );

    if ($sampleSize) {
        $self->append("Sample size: $sampleSize\n");
        $self->append("Samples:     $entries\n");
    }
    else {
        my $digits = length $entries;

        for ( 1 .. $entries ) {
            $self->append( sprintf( "  %*d: ", $digits, $_ ) );
            $sampleSize = NToSigned( $self->read(4) );
            $self->append("sample size $sampleSize\n");
            $self->{parsedSize} += $sampleSize;
        }
    }
}

sub name_stsz {
    my $self = shift;
    return 'Sample size table';
}

sub dump_stss {
    my $self = shift;

    $self->dump_stts(@_);
}

sub name_stss {
    my $self = shift;
    return 'Key frame sample numbers table';
}

sub dump_stts {
    my $self = shift;
    my ( $pos, $len ) = @_;

    $self->append( 'Version:  ', unpack( 'C',   $self->read(1) ), "\n" );
    $self->append( 'Flags:    ', unpack( 'B24', $self->read(3) ), "\n" );
    my $entries = NToSigned( $self->read(4) );
    my $digits  = length $entries;
    my $scale   = $self->findAtomValue('timescale');

    for ( 1 .. $entries ) {
        $self->append( sprintf( "  %*d\n", $digits, $_ ) );
        $self->append( '    Sample count: ', NToSigned( $self->read(4) ), "\n" );

        my $duration = NToSigned( $self->read(4) );
        my $durSecs = $scale ? $duration / $scale : '---';
        $self->append("    Duration:   $duration ticks (${durSecs} seconds)\n");
    }
}

sub name_stts {
    my $self = shift;
    return 'Sample number to duration maps';
}

sub dump_targ {
    my $self = shift;
    my ( $pos, $len ) = @_;

    $self->showUnknown();
    $self->unwrapAtoms( $pos + 12, $len - 12 );
}

sub dump_test {
    my $self = shift;
    my ( $pos, $len ) = @_;

    $self->showUnknown();
    $self->unwrapAtoms( $pos + 12, $len - 12 );
}

sub dump_tkhd {
    my $self = shift;

    $self->append( 'Version:  ', unpack( 'C',   $self->read(1) ), "\n" );
    $self->append( 'Flags:    ', unpack( 'B24', $self->read(3) ), "\n" );
    $self->append( 'Creation time:     ', $self->showDate(), "\n" );
    $self->append( 'Modification time: ', $self->showDate(), "\n" );
    $self->append( 'Track ID:          ', unpack( "N", $self->read(4) ), "\n" );
    $self->append("Reserved\n");
    $self->read(4);
    my $scale    = $self->findAtomValue('timescale');
    my $duration = NToSigned( $self->read(4) );
    my $durSecs  = $scale ? $duration / $scale : '---';
    $self->append("Duration:          $duration ticks (${durSecs} seconds)\n");
    $self->append("Reserved\n");
    $self->read(8);
    $self->append( 'Layer:             ', nToSigned( $self->read(2) ),   "\n" );
    $self->append( 'Alternate group:   ', nToSigned( $self->read(2) ),   "\n" );
    $self->append( 'Volume:            ', nToUnsigned( $self->read(2) ), "\n" );
    $self->append("Reserved\n");
    $self->read(2);
    $self->append( 'Matrix structure:  ', $self->showMatrix(),        "\n" );
    $self->append( 'Track width:       ', NToFixed( $self->read(4) ), "\n" );
    $self->append( 'Track height:      ', NToFixed( $self->read(4) ), "\n" );
}

sub name_tkhd {
    my $self = shift;
    return 'Media track header';
}

sub dump_trak {
    my $self = shift;

    $self->unwrapAtoms(@_);
}

sub name_trak {
    my $self = shift;
    return 'Media track container';
}

sub dump_trin {
    my $self = shift;
    my ( $pos, $len ) = @_;

    $self->showUnknown();
    $self->append( 'Track index: ', NToSigned( $self->read(4) ), "\n" );
}

sub name_trin {
    my $self = shift;
    return 'Track index';
}

sub dump_udta {
    my $self = shift;

    $self->unwrapAtoms(@_);
}

sub name_udta {
    my $self = shift;
    return 'User data';
}

sub dump_vmhd {
    my $self   = shift;
    my $parent = $self->{atomStack}[-2][0];

    if ( $parent eq 'minf' ) {
        $self->append( 'Version:  ', unpack( 'C',   $self->read(1) ), "\n" );
        $self->append( 'Flags:    ', unpack( 'B24', $self->read(3) ), "\n" );

        $self->showGraphicsXferMode();
        $self->showRGB();
    }
    else {
        $self->append("Unhandled context ($parent) for VideoMediaInfo atom\n");
    }
}

sub name_vmhd {
    my $self = shift;
    return 'Video media header';
}

sub dump_whic {
    my $self = shift;
    my ( $pos, $len ) = @_;
    my $dataRef = \%{ $self->getParentAttribs () };
    my %actions = (
        1024  => 'kActionMovieSetVolume',
        1025  => 'kActionMovieSetRate',
        1026  => 'kActionMovieSetLoopingFlags',
        1027  => 'kActionMovieGoToTime',
        1028  => 'kActionMovieGoToTimeByName',
        1029  => 'kActionMovieGoToBeginning',
        1030  => 'kActionMovieGoToEnd',
        1031  => 'kActionMovieStepForward',
        1032  => 'kActionMovieStepBackward',
        1033  => 'kActionMovieSetSelection',
        1034  => 'kActionMovieSetSelectionByName',
        1035  => 'kActionMoviePlaySelection',
        1036  => 'kActionMovieSetLanguage',
        1037  => 'kActionMovieChanged',
        1038  => 'kActionMovieRestartAtTime',
        2048  => 'kActionTrackSetVolume',
        2049  => 'kActionTrackSetBalance',
        2050  => 'kActionTrackSetEnabled',
        2051  => 'kActionTrackSetMatrix',
        2052  => 'kActionTrackSetLayer',
        2053  => 'kActionTrackSetClip',
        2054  => 'kActionTrackSetCursor',
        2055  => 'kActionTrackSetGraphicsMode',
        3072  => 'kActionSpriteSetMatrix',
        3073  => 'kActionSpriteSetImageIndex',
        3074  => 'kActionSpriteSetVisible',
        3075  => 'kActionSpriteSetLayer',
        3076  => 'kActionSpriteSetGraphicsMode',
        3078  => 'kActionSpritePassMouseToCodec',
        3079  => 'kActionSpriteClickOnCodec',
        3080  => 'kActionSpriteTranslate',
        3081  => 'kActionSpriteScale',
        3082  => 'kActionSpriteRotate',
        3083  => 'kActionSpriteStretch',
        4096  => 'kActionQTVRSetPanAngle',
        4097  => 'kActionQTVRSetTiltAngle',
        4098  => 'kActionQTVRSetFieldOfView',
        4099  => 'kActionQTVRShowDefaultView',
        4100  => 'kActionQTVRGoToNodeID',
        5120  => 'kActionMusicPlayNote',
        5121  => 'kActionMusicSetController',
        6144  => 'kActionCase',
        6145  => 'kActionWhile',
        6146  => 'kActionGoToURL',
        6147  => 'kActionSendQTEventToSprite',
        6148  => 'kActionDebugStr',
        6149  => 'kActionPushCurrentTime',
        6150  => 'kActionPushCurrentTimeWithLabel',
        6151  => 'kActionPopAndGotoTopTime',
        6152  => 'kActionPopAndGotoLabeledTime',
        6153  => 'kActionStatusString',
        6154  => 'kActionSendQTEventToTrackObject',
        6155  => 'kActionAddChannelSubscription',
        6156  => 'kActionRemoveChannelSubscription',
        6157  => 'kActionOpenCustomActionHandler',
        6158  => 'kActionDoScript',
        7168  => 'kActionSpriteTrackSetVariable',
        7169  => 'kActionSpriteTrackNewSprite',
        7170  => 'kActionSpriteTrackDisposeSprite',
        7171  => 'kActionSpriteTrackSetVariableToString',
        7172  => 'kActionSpriteTrackConcatVariables',
        7173  => 'kActionSpriteTrackSetVariableToMovieURL',
        7174  => 'kActionSpriteTrackSetVariableToMovieBaseURL',
        8192  => 'kActionApplicationNumberAndString',
        9216  => 'kActionQD3DNamedObjectTranslateTo',
        9217  => 'kActionQD3DNamedObjectScaleTo',
        9218  => 'kActionQD3DNamedObjectRotateTo',
        10240 => 'kActionFlashTrackSetPan',
        10241 => 'kActionFlashTrackSetZoom',
        10242 => 'kActionFlashTrackSetZoomRect',
        10243 => 'kActionFlashTrackGotoFrameNumber',
        10244 => 'kActionFlashTrackGotoFrameLabel',
        11264 => 'kActionMovieTrackAddChildMovie',
        11265 => 'kActionMovieTrackLoadChildMovie',
    );

    $self->showUnknown();

    my $action    = NToSigned( $self->read(4) );
    my $actionStr = $actions{$action};
    $actionStr = "Unknown - $action" if !defined $actionStr;
    $self->append("Type: $actionStr\n");
    $dataRef->{'ActionType'} = $actionStr;
}

sub name_whic {
    my $self = shift;
    return 'Which action type';
}

sub dump_wide {
}

sub name_wide {
    my $self = shift;
    return '64 bit expansion place holder';
}

sub dump_WLOC {
    my $self = shift;
    my ( $pos, $len ) = @_;

    $len = 2 * $len - 16;
    $self->append( unpack( "H$len\n", $self->read($len) ), "\n" );
}

sub name_WLOC {
    my $self = shift;
    return 'Default window location';
}

sub dump_x00000001 {
    my $self       = shift;
    my $parentType = $self->{atomStack}[-2][0];

    if ( $parentType eq 'oprn' ) {
        my ( $pos, $len ) = @_;

        $self->showUnknown();
        $self->unwrapAtoms( $pos + 12, $len - 12 );
    }
    else {

        $self->showBogus();
        $self->append( 'Matrix structure:  ', $self->showMatrix(), "\n" );
    }
}

sub name_x00000001 {
    my $self       = shift;
    my $parentType = $self->{atomStack}[-2][0];

    if ( $parentType eq 'oprn' ) {
        return '';
    }
    else {
        return 'kSpritePropertyMatrix';
    }
}

sub dump_x00000002 {
    my $self = shift;

    $self->showUnknown();
    $self->append( 'Value:     ', groupDigits( nToSigned( $self->read(2) ) ),
        "\n" );
}

sub name_x00000002 {
    my $self = shift;
    return 'Constant';
}

sub dump_x00000004 {
    my $self = shift;

    $self->showBogus();
    $self->append( 'Visible:  ', nToSigned( $self->read(2) ), "\n" );
}

sub name_x00000004 {
    my $self = shift;
    return 'kSpritePropertyVisible';
}

sub dump_x00000005 {
    my $self = shift;

    $self->showBogus();
    $self->append( 'Layer:  ', nToSigned( $self->read(2) ), "\n" );
}

sub name_x00000005 {
    my $self = shift;
    return 'kSpritePropertyLayer';
}

sub dump_x00000006 {
    my $self = shift;

    $self->showPlayMode();
    $self->showBogus();
    $self->showRGB();
}

sub name_x00000006 {
    my $self = shift;
    return 'kSpritePropertyGraphicsMode';
}

sub dump_x00000015 {
}

sub name_x00000015 {
    my $self = shift;
    return 'Quicktime version';
}

sub dump_x00000064 {
    my $self = shift;
    $self->showBogus();
    $self->append( 'Image index: ', nToSigned( $self->read(2) ), "\n" );
}

sub name_x00000064 {
    my $self = shift;
    return 'kSpritePropertyImageIndex';
}

sub dump_x00000065 {
    my $self = shift;

    $self->append("Background colour:\n");
    $self->showBogus();
    $self->showRGB();
}

sub name_x00000065 {
    my $self = shift;
    return 'kSpriteTrackPropertyBackgroundColor';
}

sub dump_x00000066 {
    my $self = shift;
    $self->showBogus();
    $self->append( 'Offscreen bit depth: ', nToSigned( $self->read(2) ), "\n" );
}

sub name_x00000066 {
    my $self = shift;
    return 'kSpriteTrackPropertyOffscreenBitDepth';
}

sub dump_x00000067 {
    my $self = shift;
    $self->showBogus();
    $self->append( 'Sample format: ', nToSigned( $self->read(2) ), "\n" );
}

sub name_x00000067 {
    my $self = shift;
    return 'kSpriteTrackPropertySampleFormat';
}

sub dump_x00000069 {
    my $self = shift;
    $self->showBogus();
    $self->append( 'Has Actions: ', cToBool( $self->read(1) ), "\n" );
}

sub name_x00000069 {
    my $self = shift;
    return 'kSpriteTrackPropertySampleFormat';
}

sub dump_x0000006a {
    my $self = shift;
    $self->showBogus();
    $self->append( 'Visible: ', cToBool( $self->read(1) ), "\n" );
}

sub name_x0000006a {
    my $self = shift;
    return 'kSpriteTrackPropertyScaleSpritesToScaleWorld';
}

sub dump_x0000006b {
    my $self = shift;
    $self->showBogus();

    my $interval = NToUnsigned( $self->read(4) );
    my $freq = $interval ? ( 60.0 / $interval ) . ' Hz' : 'fastest';

    $freq = 'off' if $interval == 0xffffffff;
    $self->append("Idle Events: $freq\n");
}

sub name_x0000006b {
    my $self = shift;
    return 'kSpriteTrackPropertyHasActions';
}

sub dump_x00000c00 {
}

sub name_x00000c00 {
    my $self = shift;
    return 'kOperandSpriteBoundsLeft';
}

sub dump_x00000c01 {
}

sub name_x00000c01 {
    my $self = shift;
    return 'kOperandSpriteBoundsTop';
}

sub dump_x00000c02 {
}

sub name_x00000c02 {
    my $self = shift;
    return 'kOperandSpriteBoundsRight';
}

sub dump_x00000c03 {
}

sub name_x00000c03 {
    my $self = shift;
    return 'kOperandSpriteBoundsBottom';
}

sub dump_x00000c04 {
}

sub name_x00000c04 {
    my $self = shift;
    return 'kOperandSpriteImageIndex';
}

sub dump_x00000c05 {
}

sub name_x00000c05 {
    my $self = shift;
    return 'kOperandSpriteVisible';
}

sub dump_x00000c06 {
}

sub name_x00000c06 {
    my $self = shift;
    return 'kOperandSpriteLayer';
}

sub dump_x00000c07 {
    my $self = shift;
    my ( $pos, $len ) = @_;

    $self->setParentAttribs (ActionType => 'kOperandSpriteTrackVariable');
    $self->showUnknown();
    $self->unwrapAtoms( $pos + 12, $len - 12 );
}

sub name_x00000c07 {
    my $self = shift;
    return 'kOperandSpriteTrackVariable';
}

sub dump_x00001400 {
}

sub name_x00001400 {
    my $self = shift;
    return 'kOperandMouseLocalHLoc';
}

sub dump_x00001401 {
}

sub name_x00001401 {
    my $self = shift;
    return 'kOperandMouseLocalVLoc';
}

sub dump_x00001402 {
}

sub name_x00001402 {
    my $self = shift;
    return 'kOperandKeyIsDown';
}

sub dumpBlock {
    my $self = shift;
    my ( $pos, $len ) = @_;

    while ($len) {
        my $chunk = $len > 16 ? 16 : $len;
        my $str = $self->read($chunk);

        $str =~ s/([\x00-\x1f\x80-\xff])/sprintf "\\x%02x", ord ($1)/ge;
        $self->append("$str\n");
        $len -= $chunk;
    }
}

sub dumpText {
    my $self = shift;
    my ( $pos, $len ) = @_;

    $self->append( unpack( "a$len", $self->read($len) ), "\n" );
}

sub dumpUnicodeText {
    my $self = shift;
    my ( $pos, $len ) = @_;

    my $rawStr = "\xff\xfe" . unpack( "a$len", $self->read($len) );
    my $str = decode( "utf16", $rawStr );
    $self->append( $str, "\n" );
}

sub groupDigits {
    my $num = reverse shift;

    $num =~ s/(\d{3}(?=\d))/$1,/g;
    return scalar reverse $num;
}

sub show {
    local $_;
    my $thing = shift;
    if ( $thing =~ /^([^\x00]*)\x00\Z/ ) {
        return $1;
    }
    elsif ( $thing =~ /[\x00-\x1f]/ ) {
        my $sum = 0;
        my @chars = split '', $thing;
        $sum = $sum * 256 + ord($_) for @chars;
        return sprintf "0x%0x", $sum;
    }

    return $thing;
}

sub showBogus {
    my $self = shift;

    $self->append( 'Version:  ', unpack( 'C',   $self->read(1) ), "\n" );
    $self->append( 'Flags:    ', unpack( 'B24', $self->read(3) ), "\n" );
    $self->append("Reserved\n");
    $self->read(8);
}

sub showPlayMode {
    my $self     = shift;
    my $flagBits = shift;
    my $flags    = '';

    $flagBits = $self->read(4) if !defined $flagBits;
    $flagBits = NToSigned($flagBits);

    $flags .= 'fullScreenHideCursor '        if $flags & 1;
    $flags .= 'fullScreenAllowEvents '       if $flags & 2;
    $flags .= 'fullScreenDontChangeMenuBar ' if $flags & 4;
    $flags .= 'fullScreenPreflightSize '     if $flags & 8;
    $self->append("Play mode flags: $flags\n");
}

sub showGMode {
    my $self  = shift;
    my $gMode = shift;
    $gMode = $self->read(2) if !defined $gMode;
    $gMode = NToSigned($gMode);

    my %modes = (
        0x0000 => 'Copy',
        0x0040 => 'Dither copy',
        0x0020 => 'Blend',
        0x0024 => 'Transparent',
        0x0100 => 'Straight alpha',
        0x0101 => 'Premul white alpha',
        0x0102 => 'Premul black alpha',
        0x0104 => 'Straight alpha blend',
        0x0103 => 'Composition (dither copy)',
    );

    $self->append("Graphics mode: $modes{$gMode}\n");
}

sub showRGB {
    my $self = shift;
    my ( $red, $green, $blue ) = @_;

    $red   = $self->read(2) if !defined $red;
    $green = $self->read(2) if !defined $green;
    $blue  = $self->read(2) if !defined $blue;
    $red   = nToUnsigned($red);
    $green = nToUnsigned($green);
    $blue  = nToUnsigned($blue);

    $self->append("Red:   $red\n");
    $self->append("Green: $green\n");
    $self->append("Blue:  $blue\n");
}

sub showGraphicsXferMode {
    my $self  = shift;
    my $gMode = shift;

    $gMode = $self->read(2) if !defined $gMode;
    $gMode = nToSigned($gMode);

    my %modes = (
        0  => 'srcCopy',
        1  => 'srcOr',
        2  => 'srcXor',
        3  => 'srcBic',
        4  => 'notSrcCopy',
        5  => 'notSrcOr',
        6  => 'notSrcXor',
        7  => 'notSrcBic',
        8  => 'patCopy',
        9  => 'patOr',
        10 => 'patXor',
        11 => 'patBic',
        12 => 'notPatCopy',
        13 => 'notPatOr',
        14 => 'notPatXor',
        15 => 'notPatBic',
        49 => 'grayishTextOr',
        50 => 'hilite',
        50 => 'hilitetransfermode',
        32 => 'blend',
        33 => 'addPin',
        34 => 'addOver',
        35 => 'subPin',
        37 => 'addMax',
        37 => 'adMax',
        38 => 'subOver',
        39 => 'adMin',
        64 => 'ditherCopy',
        36 => 'transparent',
    );

    if ( exists $modes{$gMode} ) {
        $self->append( 'Mode:  ', $modes{$gMode}, "\n" );
    }
    else {
        $self->append( 'Mode:  unknown - ', $gMode, "\n" );
    }
}

sub showDate {
    my $self  = shift;
    my $stamp = shift;

    $stamp = $self->read(4) if !defined $stamp;
    $stamp = NToUnsigned($stamp);

    # seconds difference between Mac epoch and Unix/Windows.
    my $mod =
        ( $^O =~ /MSWin32/ )
      ? ( 2063824538 - 12530100 + 31536000 )
      : ( 2063824538 - 12530100 );
    my $date =
      ( $^O =~ /Mac/ ) ? localtime($stamp) : localtime( $stamp - $mod );
    return $date;
}

sub showMatrix {
    my $self   = shift;
    my $matrix = shift;

    $matrix = $self->read(36) if !defined $matrix;

    my $str = '';
    for ( 1 .. 3 ) {
        my $sub = substr $matrix, 0, 12, '';
        $str .= NToFixed( substr $sub, 0, 4, '' ) . ' ';
        $str .= NToFixed( substr $sub, 0, 4, '' ) . ' ';
        $str .= NToFrac( substr $sub, 0, 4, '' ) . ' ';
        $str .= ' / ' if $_ != 3;
    }

    return $str;
}

sub showStr {
    my $self = shift;
    my $pos  = shift;
    my ( $len, $key ) = unpack( "Na4", $self->read( 8, $pos ) );

    $len -= 12;
    $self->append( unpack( "a$len", $self->read( $len, $pos + 12 ) ), "\n" );
}

sub showUnknown {
    my $self = shift;

    $self->append( 'Unknown 1: ', groupDigits( NToSigned( $self->read(4) ) ),
        "\n" );
    $self->append( 'Unknown 2: ', groupDigits( NToSigned( $self->read(4) ) ),
        "\n" );
    $self->append( 'Unknown 3: ', groupDigits( NToSigned( $self->read(4) ) ),
        "\n" );
}

sub get4Char {
    my $self = shift;
    return unpack( "a4", $self->read(4) );
}

sub NToFixed {
    my $str = shift;
    return unpack( 'l', pack( 'l', unpack( "N", $str ) ) ) / 0x10000;
}

sub fToFloat {
    my $str = shift;
    return unpack( 'l', pack( 'l', unpack( "f", $str ) ) );
}

sub NToFrac {
    my $str = shift;
    my $fract = unpack( 'l', pack( 'l', unpack( "N", $str ) ) );
    return $fract / 0x40000000;
}

sub NToSigned {
    my $str = shift;
    return unpack( 'l', pack( 'l', unpack( "N", $str ) ) );
}

sub NToUnsigned {
    my $str = shift;
    return unpack( 'L', pack( 'L', unpack( "N", $str ) ) );
}

sub NToHex {
    my $str = shift;
    return '0x' . unpack( 'H8', pack( 'L', unpack( "N", $str ) ) );
}

sub NToBin {
    my $str = shift;
    return unpack( 'B32', pack( 'L', unpack( "N", $str ) ) );
}

sub nToSigned {
    my $str = shift;
    return unpack( 's', pack( 's', unpack( "n", $str ) ) );
}

sub nToUnsigned {
    my $str = shift;
    return unpack( 'S', pack( 'S', unpack( "n", $str ) ) );
}

sub cToBool {
    my $str = shift;
    return ord($str);
}

1;


=head2 Subclassing QuickTime

Because there are a huge number of atom types used by QuickTime (many of them
undocumented) and the number of atom types used is increasing over time,
Video::Dumper::QuickTime makes no attempt to decode all atom types. Instead it is
easy to subclass the QuickTime class to add decoders for atoms of interest, or
to change the way atoms that are currently handled by the QuickTime class are
decoded for some particular application.

Two methods need to be provided for decoding of an atom. They are of the form:

    sub name_xxxx {
        my $self = shift;
        return 'The xxxx atom';
    }

    sub dump_xxxx {
        my $self = shift;
        my ( $pos, $len ) = @_;

        ...
    }

where the C<xxxx> is a placeholder for the atom four char code.

A complete subclass package that handles one atom might look like:

    package Subclass;

    use QuickTime;
    use base qw(QuickTime);

    sub name_smhd {
        my $self = shift;
        return 'The smhd atom';
    }

    sub dump_smhd {
        my $self = shift;
        my ( $pos, $len ) = @_;
    }

There is of course no limit practical to the number of handlers added by a
subclass.

=head1 REMARKS

This module recognises a subset of the atoms actually used by QuickTime files.
Generally, well formed files should not present a problem because unrecognised
atoms will be reported and skipped.

Subclassing Video::Dumper::QuickTime as shown above allows handlers to be added
for unrecognised atoms. The author would appreciate any such handler code being
forwarded for inclusion in future versions of the module.

=head1 BUGS

Please report any bugs or feature requests to
C<bug-video-dumper-quicktime at rt.cpan.org>, or through the web interface at
L<http://rt.cpan.org/NoAuth/ReportBug.html?Queue=Video-Dumper-QuickTime>.
I will be notified, and then you'll automatically be notified of progress on
your bug as I make changes.

=head1 SUPPORT

This module is supported by the author through CPAN. The following links may be
of assistance:

=over 4

=item * AnnoCPAN: Annotated CPAN documentation

L<http://annocpan.org/dist/Video-Dumper-QuickTime>

=item * CPAN Ratings

L<http://cpanratings.perl.org/d/Video-Dumper-QuickTime>

=item * RT: CPAN's request tracker

L<http://rt.cpan.org/NoAuth/Bugs.html?Dist=Video-Dumper-QuickTime>

=item * Search CPAN

L<http://search.cpan.org/dist/Video-Dumper-QuickTime>

=back

=head1 AUTHOR

    Peter Jaquiery
    CPAN ID: GRANDPA
    grandpa@cpan.org

=head1 COPYRIGHT & LICENSE

This program is free software; you can redistribute
it and/or modify it under the same terms as Perl itself.

The full text of the license can be found in the
LICENSE file included with this module.

=head1 SEE ALSO

=cut

