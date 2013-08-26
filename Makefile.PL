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
        'Gtk2' => 0,
        'Gtk2::SourceView2' => 0,
    },
    dist                => { COMPRESS => 'gzip -9f', SUFFIX => 'gz', },
);
