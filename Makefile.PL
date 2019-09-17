#! /usr/bin/perl -w
use strict;
use warnings;
use ExtUtils::MakeMaker;

WriteMakefile(
    NAME                => 'dotconsole',
    AUTHOR              => q{Richard Kettlewell <rjk@greenend.org.uk>},
    VERSION_FROM        => 'lib/Greenend/DotConsole/Window.pm',
    ABSTRACT            => "interactive editor for Graphviz source files",
    LICENSE             => 'gpl',
    EXE_FILES => [ 'bin/dotconsole' ],
    PREREQ_PM => {
        'Gtk3' => 0,
        'Gtk3::SourceView' => 0,
    },
    dist                => { COMPRESS => 'gzip -9f', SUFFIX => 'gz', },
);
