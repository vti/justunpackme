package Unpacker::App::Directory;

use strict;
use warnings;

use parent qw(Plack::App::Directory);

use Plack::Util;
use Lamework::Registry;

sub sort_files {
    my $self = shift;
    my ($dir, $files) = @_;

    my @dirs;
    my @files;

    foreach my $file (@$files) {
        if (-d "$dir/$file") {
            next if $file eq '..';
            push @dirs, $file;
            next;
        }

        push @files, $file;
    }

    return (sort { $a cmp $b } @dirs), (sort { $a cmp $b } @files);
}

sub to_html {
    my $self = shift;
    my ($env, $files) = @_;

    my @files;
    foreach my $file (@$files) {
        my $info = {};
        @$info{qw(url basename size mime_type mtime)} = @$file;
        push @files, $info;
    }

    my $displayer = Lamework::Registry->get('displayer');
    return $displayer->render_file(
        'listing.caml',
        layout => 'layout.caml',
        vars   => {
            path  => $env->{PATH_INFO},
            files => \@files
        }
    );
}

1;
