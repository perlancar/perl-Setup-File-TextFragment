package Setup::File::TextFragment;

use 5.010001;
use strict;
use warnings;
use Log::Any '$log';

use File::Trash::Undoable;
use Text::Fragment;

# VERSION

require Exporter;
our @ISA       = qw(Exporter);
our @EXPORT_OK = qw(setup_text_fragment);

our %SPEC;

$SPEC{setup_text_fragment} = {
    v           => 1.1,
    summary     => 'Insert/delete text fragment in a file',
    description => <<'_',

On do, will insert fragment to file (or delete, if `should_exist` is set to
false). On undo, will restore old file.

Unfixable state: file does not exist or not a regular file (directory and
symlink included).

Fixed state: file exists, fragment already exists and with the same content (if
`should_exist` is true) or fragment already does not exist (if `should_exist` is
false).

Fixable state: file exists, fragment doesn't exist or payload is not the same
(if `should_exist` is true) or fragment still exists (if `should_exist` is
false).

_
    args        => {
        path => {
            summary => 'Path to file',
            schema => 'str*',
            req    => 1,
            pos    => 0,
        },
        id => {
            summary => 'Fragment ID',
            schema => 'str*',
            req    => 1,
            pos    => 1,
        },
        payload => {
            summary => 'Fragment content',
            schema => 'str*',
            req    => 1,
            pos    => 2,
        },
        attrs => {
            summary => 'Fragment attributes (only for inserting new fragment)'.
                ', passed to Text::Fragment',
            schema => 'hash',
        },
        top_style => {
            summary => 'Will be passed to Text::Fragment',
            schema => 'bool',
        },
        comment_style => {
            summary => 'Will be passed to Text::Fragment',
            schema => 'bool',
        },
        label => {
            summary => 'Will be passed to Text::Fragment',
            schema => 'str',
        },
        replace_pattern => {
            summary => 'Will be passed to Text::Fragment',
            schema => 'str',
        },
        good_pattern => {
            summary => 'Will be passed to Text::Fragment',
            schema => 'str',
        },
        should_exist => {
            summary => 'Whether fragment should exist',
            schema => [bool => {default=>1}],
        },
    },
    features => {
        tx => {v=>2},
        idempotent => 1,
    },
};
sub setup_text_fragment {
    my %args = @_;

    # TMP, schema
    my $tx_action       = $args{-tx_action} // '';
    my $taid            = $args{-tx_action_id}
        or return [400, "Please specify -tx_action_id"];
    my $dry_run         = $args{-dry_run};
    my $path            = $args{path};
    defined($path) or return [400, "Please specify path"];
    my $id              = $args{id};
    defined($id) or return [400, "Please specify id"];
    my $payload         = $args{payload};
    defined($payload) or return [400, "Please specify payload"];
    my $attrs           = $args{attrs};
    my $comment_style   = $args{comment_style};
    my $top_style       = $args{top_style};
    my $label           = $args{label};
    my $replace_pattern = $args{replace_pattern};
    my $good_pattern    = $args{good_pattern};
    my $should_exist    = $args{should_exist} // 1;

    my $is_sym  = (-l $path);
    my @st      = stat($path);
    my $exists  = $is_sym || (-e _);
    my $is_file = (-f _);

    my @cmd;

    return [412, "$path does not exist"] unless $exists;
    return [412, "$path is not a regular file"] if $is_sym||!$is_file;

    open my($fh), "<", $path or return [500, "Can't open $path: $!"];
    my $text = do { local $/; ~~<$fh> };

    my $res;
    if ($should_exist) {
        $res = Text::Fragment::insert_fragment(
            text=>$text, id=>$id, payload=>$payload,
            comment_style=>$comment_style, label=>$label, attrs=>$attrs,
            good_pattern=>$good_pattern, replace_pattern=>$replace_pattern,
            top_style=>$top_style,
        );
    } else {
        $res = Text::Fragment::delete_fragment(
            text=>$text, id=>$id,
            comment_style=>$comment_style, label=>$label,
        );
    }

    return $res if $res->[0] == 304;
    return $res if $res->[0] != 200;

    if ($tx_action eq 'check_state') {
        if ($should_exist) {
            $log->info("(DRY) Inserting fragment $id to $path ...")
                if $dry_run;
        } else {
            $log->info("(DRY) Deleting fragment $id from $path ...")
                if $dry_run;
        }
        return [200, "Fragment $id needs to be inserted to $path", undef,
                {undo_actions=>[
                    ['File::Trash::Undoable::untrash', # restore old file
                     {path=>$path, suffix=>substr($taid,0,8)}],
                    ['File::Trash::Undoable::trash',   # trash new file
                     {path=>$path, suffix=>substr($taid,0,8)."n"}],
                ]}];
    } elsif ($tx_action eq 'fix_state') {
        if ($should_exist) {
            $log->info("Inserting fragment $id to $path ...");
        } else {
            $log->info("Deleting fragment $id from $path ...");
        }

        File::Trash::Undoable::trash(
            path=>$path, suffix=>substr($taid,0,8), -tx_action=>'fix_state');
        open my($fh), ">", $path or return [500, "Can't open: $!"];
        print $fh $res->[2]{text};
        close $fh or return [500, "Can't write: $!"];
        chmod $st[2] & 07777, $path; # XXX ignore error?
        unless ($>) { chown $st[4], $st[5], $path } # XXX ignore error?
        return [200, "OK"];
    }
    [400, "Invalid -tx_action"];
}

1;
# ABSTRACT: Insert/delete text fragment in a file, with undo support

=head1 SEE ALSO

L<Text::Fragment>

L<Setup>

=cut
