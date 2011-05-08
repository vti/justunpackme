package Unpacker::Action::Fetch;

use strict;
use warnings;

use base 'Unpacker::Action::Archive';

use Input::Validator;
use Try::Tiny;
use Unpacker::Fetcher;
use Regexp::Common qw(URI);

sub run {
    my $self = shift;

    my $validator = Input::Validator->new;
    $validator->field('url')->required(1)->regexp(qr/^$RE{URI}{HTTP}$/);

    if ($validator->validate($self->req->parameters)) {
        my $url = $validator->values->{url};

        my $max_size_in_megs =
          Lamework::Registry->get('config')->{max_fetch_size} || 10;

        try {
            my $fetcher =
              Unpacker::Fetcher->new(
                max_file_size => $max_size_in_megs * 1024 * 1024);
            $fetcher->fetch($url);

            my $archive = $self->_unpack_archive($fetcher->path);

            return $self->redirect('view', path => $archive->rel_path, tail => '');
        }
        catch {
            my $e = $_;

            die $e unless ref $e && $e->isa('Lamework::Exception');

            $self->set_var('fetch_errors' => {url => $e->error});
        }
    }
    else {
        $self->set_var('fetch_errors' => $validator->errors);
    }
}

1;
