package Unpacker::Fetcher;

use strict;
use warnings;

use File::Temp ();
use HTTP::Request;
use LWP::UserAgent;

use Unpacker::FetcherException;

sub new {
    my $class = shift;

    my $self = {@_};
    bless $self, $class;

    $self->{max_file_size} ||= 10 * 1024 * 1024; # 10M

    return $self;
}

sub fetch {
    my $self = shift;
    my ($url) = @_;

    if ($self->_get_content_length_with_head($url) > $self->{max_file_size}) {
        Unpacker::FetcherException->throw('Archive is too large');
    }

    my $ua = LWP::UserAgent->new(timeout => 5, max_size => $self->{max_file_size});

    my $file = $self->{file} = File::Temp->new;

    my $req = HTTP::Request->new(GET => $url);

    my $res = $ua->request(
        $req => sub {
            my ($chunk, $res) = @_;

            print $file $chunk;
        }
    );

    if (!$res->is_success) {
        Unpacker::FetcherException->throw('Fetching archive failed');
    }
    elsif ($res->header("Client-Aborted")) {
        Unpacker::FetcherException->throw('Archive is too large');
    }

    return $self;
}

sub path { shift->{file}->filename }

sub _get_content_length_with_head {
    my $self = shift;
    my ($url) = @_;

    my $ua = LWP::UserAgent->new;

    my $req = HTTP::Request->new('HEAD' => $url);

    my $res = $ua->request($req);

    return 0 unless $res->is_success;

    return int($res->header('Content-Length') || 0);
}

1;
