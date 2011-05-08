#!/usr/bin/env perl

use 5.008007;

use strict;
use warnings;

use ExtUtils::MakeMaker;

my ($mm) = $ExtUtils::MakeMaker::VERSION =~ /^([^_]+)/;

WriteMakefile(
    NAME         => 'Unpacker',
    VERSION_FROM => 'lib/Unpacker.pm',
    ABSTRACT     => '',
    AUTHOR       => 'vti <vti@cpan.org>',

    ($mm < 6.3002 ? () : ('LICENSE' => 'artistic_2')),

    (   $mm < 6.46
        ? ()
        : ( META_MERGE => {
                requires  => {perl      => '5.008007'},
                resources => {license   => 'http://dev.perl.org/licenses/'},
                no_index  => {directory => [qw/t/]}
            },
            META_ADD => {
                build_requires     => {},
                configure_requires => {}
            },
        )
    ),

    PREREQ_PM => {
        'File::MimeInfo::Magic'   => 0,
        'File::Unpack'            => 0,
        'Input::Validator'        => 0,
        'LWP'                     => 0,
        'Mozilla::CA'             => 0,
        'Plack'                   => 0,
        'Regexp::Common'          => 0,
        'Try::Tiny'               => 0,
    },
    test => {TESTS => 't/*.t t/*/*.t'}
);
