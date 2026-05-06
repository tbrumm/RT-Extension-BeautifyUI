package RT::Extension::BeautifyUI;

our $VERSION = '2.3.0';

use strict;
use warnings;
use LWP::UserAgent;
use XML::LibXML;
use JSON::PP ();
use Encode qw(decode);

RT->AddStyleSheets('beautify-ui.css');
RT->AddStyleSheets('lifecycle-widget.css');

# Register all dashboard widgets automatically
{
    my @widgets = qw(
        ClockWidget
        WeatherWidget
        ArticlesWidget
        AssetsWidget
        UserProfileWidget
        TodaysHolidays
        FeedWidget
    );
    my $components = RT->Config->Get('HomepageComponents');
    my %existing   = map { $_ => 1 } @{$components};
    my @to_add     = grep { !$existing{$_} } @widgets;
    if (@to_add) {
        RT->Config->Set( 'HomepageComponents', [ @{$components}, @to_add ] );
    }
}

# Allow HTMX requests to the feed endpoints through the CSRF Referer check
{
    my %refs = RT->Config->Get('ReferrerComponents');
    $refs{'/FeedWidget/Fetch.html'}     = 1;
    $refs{'/FeedWidget/SaveFeeds.html'} = 1;
    RT->Config->Set( 'ReferrerComponents', %refs );
}

# -----------------------------------------------------------------------
# FeedWidget — user feed configuration (stored as RT user attribute)
# -----------------------------------------------------------------------

sub GetUserFeeds {
    my ( $class, $user ) = @_;
    my $attr = $user->FirstAttribute('FeedWidgetFeeds');
    return [] unless $attr && $attr->Content;
    my $data = eval { JSON::PP->new->decode( $attr->Content ) };
    return ref($data) eq 'ARRAY' ? $data : [];
}

sub SetUserFeeds {
    my ( $class, $user, $feeds ) = @_;
    my $json = JSON::PP->new->encode($feeds);
    $user->SetAttribute( Name => 'FeedWidgetFeeds', Content => $json );
}

# -----------------------------------------------------------------------
# FeedWidget — feed fetching and parsing
# -----------------------------------------------------------------------

my $UA;

sub _ua {
    return $UA if $UA;
    $UA = LWP::UserAgent->new(
        agent        => 'RT-BeautifyUI/' . $VERSION . ' (RT/' . $RT::VERSION . ')',
        timeout      => 15,
        max_redirect => 5,
    );
    $UA->ssl_opts( verify_hostname => 0 );
    return $UA;
}

sub FetchFeed {
    my ( $class, $url, $max_items ) = @_;
    $max_items //= 10;

    my $res = eval { _ua()->get($url) };
    if ( $@ || !$res || !$res->is_success ) {
        my $err = $@ || ( $res ? $res->status_line : 'request failed' );
        return { error => $err, items => [] };
    }

    my $content = $res->decoded_content( charset => 'utf-8' );
    return _parse_feed( $content, $max_items );
}

sub _parse_feed {
    my ( $content, $max_items ) = @_;

    my $doc = eval {
        my $parser = XML::LibXML->new( recover => 2, no_network => 1 );
        $parser->parse_string($content);
    };
    return { error => 'XML parse error: ' . $@, items => [] } if $@;

    my $root = $doc->documentElement;
    return { error => 'Empty document', items => [] } unless $root;

    my $ns  = $root->namespaceURI // '';
    my $tag = $root->localname    // $root->nodeName;

    if ( $tag eq 'feed' || $ns =~ m{atom}i ) {
        return _parse_atom( $doc, $max_items );
    }
    return _parse_rss( $doc, $max_items );
}

sub _text {
    my ($node) = @_;
    return '' unless $node;
    my $t = $node->textContent // '';
    $t =~ s/^\s+|\s+$//g;
    return $t;
}

sub _parse_atom {
    my ( $doc, $max_items ) = @_;

    my $xpc = XML::LibXML::XPathContext->new($doc);
    $xpc->registerNs( 'a', 'http://www.w3.org/2005/Atom' );

    my $title = _text( ( $xpc->findnodes('//a:feed/a:title') )[0] );
    $title ||= _text( ( $doc->findnodes('//*[local-name()="title"]') )[0] );

    my @entries = $xpc->findnodes('//a:entry');
    @entries = $doc->findnodes('//*[local-name()="entry"]') unless @entries;

    my @items;
    for my $entry ( @entries[ 0 .. $max_items - 1 ] ) {
        last unless $entry;

        my $item_title = _text( ( $xpc->findnodes( 'a:title', $entry ) )[0] );
        $item_title ||= _text( ( $entry->findnodes('*[local-name()="title"]') )[0] );

        my $link_node = ( $xpc->findnodes( 'a:link[@rel="alternate" or not(@rel)]', $entry ) )[0];
        $link_node ||= ( $entry->findnodes('*[local-name()="link"]') )[0];
        my $link = $link_node ? ( $link_node->getAttribute('href') || _text($link_node) ) : '';

        my $summary = _text( ( $xpc->findnodes( 'a:summary', $entry ) )[0] );
        $summary ||= _text( ( $xpc->findnodes( 'a:content', $entry ) )[0] );
        $summary ||= _text( ( $entry->findnodes('*[local-name()="summary"]') )[0] );
        $summary = _truncate($summary, 200);

        my $pub = _text( ( $xpc->findnodes( 'a:published|a:updated', $entry ) )[0] );
        $pub ||= _text( ( $entry->findnodes('*[local-name()="published"]|*[local-name()="updated"]') )[0] );

        push @items, {
            title   => $item_title,
            link    => $link,
            summary => $summary,
            pubdate => _format_date($pub),
        };
    }

    return { feed_title => $title, items => \@items };
}

sub _parse_rss {
    my ( $doc, $max_items ) = @_;

    my $title = _text( ( $doc->findnodes('//*[local-name()="channel"]/*[local-name()="title"]') )[0] );

    my @entries = $doc->findnodes('//*[local-name()="item"]');

    my @items;
    for my $entry ( @entries[ 0 .. $max_items - 1 ] ) {
        last unless $entry;

        my $item_title = _text( ( $entry->findnodes('*[local-name()="title"]') )[0] );

        my $link_node = ( $entry->findnodes('*[local-name()="link"]') )[0];
        my $link = $link_node ? _text($link_node) : '';
        if ( !$link && $link_node ) {
            my $sib = $link_node->nextSibling;
            $link = $sib->textContent if $sib;
        }

        my $summary = _text( ( $entry->findnodes('*[local-name()="description"]') )[0] );
        $summary = _truncate($summary, 200);

        my $pub = _text( ( $entry->findnodes('*[local-name()="pubDate"]|*[local-name()="date"]|*[local-name()="published"]') )[0] );

        push @items, {
            title   => $item_title,
            link    => $link,
            summary => _strip_html($summary),
            pubdate => _format_date($pub),
        };
    }

    return { feed_title => $title, items => \@items };
}

sub _strip_html {
    my ($html) = @_;
    return '' unless defined $html;
    $html =~ s/<[^>]+>//g;
    $html =~ s/&amp;/&/g;
    $html =~ s/&lt;/</g;
    $html =~ s/&gt;/>/g;
    $html =~ s/&quot;/"/g;
    $html =~ s/&#39;/'/g;
    $html =~ s/&nbsp;/ /g;
    $html =~ s/\s+/ /g;
    $html =~ s/^\s+|\s+$//g;
    return $html;
}

sub _truncate {
    my ( $text, $max ) = @_;
    $text = _strip_html($text);
    return $text if length($text) <= $max;
    return substr( $text, 0, $max ) . '...';
}

sub _format_date {
    my ($raw) = @_;
    return '' unless $raw;
    $raw =~ s/^\s+|\s+$//g;
    if ( $raw =~ /(\d{4})-(\d{2})-(\d{2})/ ) {
        return "$3.$2.$1";
    }
    if ( $raw =~ /(\d{1,2})\s+(\w+)\s+(\d{4})/ ) {
        return "$1. $2 $3";
    }
    return $raw;
}

=head1 NAME

RT::Extension::BeautifyUI - Visual enhancements, UI polish, and dashboard widgets for Request Tracker 6

=head1 DESCRIPTION

Consolidates all custom visual improvements and dashboard widgets for RT 6
into a single installable extension. Replaces the following standalone
extensions: C<RT-Extension-ArticlesWidget>, C<RT-Extension-AssetsWidget>,
C<RT-Extension-ClockWidget>, C<rt-extension-public-holidays>,
C<RT-Extension-UserProfileWidget>, C<RT-Extension-WeatherWidget>,
C<RT-Extension-FeedWidget>.

=head2 Visual Enhancements

=over 4

=item * Bootstrap Icons loaded globally (via CDN) with section icons on ticket,
asset and article widgets

=item * Coloured icons for the main navigation menu

=item * Ticket list column enhancements: owner highlighted in colour, status
badge with "New Reply" indicator, due-date and SLA coloured badges, pending
ticket badge, avatar thumbnails for requestor / CC / AdminCC columns

=item * Due-date colour coding on the ticket display widget (AfterDue callback)

=item * SLA colour coding on the ticket display widget (ShowBasics callback)

=item * Article card styling (hover accent border, 2-line summary clamp, empty
state icon)

=item * Action-results and dependency-status banner styling

=item * Priority badge colours (low / medium / high / on_fire)

=back

=head2 Dashboard Widgets

=over 4

=item * B<ClockWidget> — analogue flip clock showing local time

=item * B<WeatherWidget> — live weather from Open-Meteo, geocoded via the
user's City / Zip / Country profile fields

=item * B<ArticlesWidget> — 5 newest knowledge-base articles

=item * B<AssetsWidget> — 5 most recently updated active assets

=item * B<UserProfileWidget> — current user's profile card with photo and
contact details

=item * B<TodaysHolidays> — worldwide public holidays for today from a
bundled CSV dataset; also shows a banner on the RT login page

=item * B<FeedWidget> — tab-based RSS/ATOM feed reader; each user configures
their own feeds on the About Me preferences page; feeds are fetched
server-side with a 15-minute session cache

=back

=head2 Ticket Display Widgets

=over 4

=item * B<LinkedArticles> — sidebar widget on the ticket display page listing
all articles linked to the current ticket (name, class, summary). The widget
is hidden when no articles are linked and refreshes automatically via HTMX
when links change.

=back

=head1 INSTALLATION

    perl Makefile.PL
    make
    sudo make install

=head2 Register the plugin

Add to F</opt/rt6/etc/RT_SiteConfig.pm>:

    Plugin('RT::Extension::BeautifyUI');

All dashboard widgets including FeedWidget are registered automatically.
The CSRF whitelist for FeedWidget endpoints is applied automatically too —
no manual C<%ReferrerComponents> entry is required.

=head2 Deploy the holidays CSV

    cp /opt/rt6/local/plugins/RT-Extension-BeautifyUI/etc/holidays-worldwide.csv \
       /opt/rt6/local/etc/holidays-worldwide.csv

=head2 Optional configuration

    # Temperature unit for WeatherWidget (default: celsius)
    Set(%WeatherWidgetOptions,
        TemperatureUnit => 'celsius',   # or 'fahrenheit'
    );

    # Custom path for the holidays CSV (default: $RT::LocalEtcPath/holidays-worldwide.csv)
    Set($HolidaysCSVPath, '/opt/rt6/local/etc/holidays-worldwide.csv');

=head2 Clear cache and restart

    sudo systemctl stop apache2
    sudo rm -rf /opt/rt6/var/mason_data/obj/*
    sudo systemctl start apache2

=head1 MIGRATION FROM STANDALONE EXTENSIONS

If you previously loaded the individual extensions, remove them from your
C<RT_SiteConfig.pm> Plugin list and from C<HomepageComponents> (now managed
automatically by this extension):

    # Remove from RT_SiteConfig.pm:
    Plugin('RT::Extension::ClockWidget');
    Plugin('RT::Extension::WeatherWidget');
    Plugin('RT::Extension::ArticlesWidget');
    Plugin('RT::Extension::AssetsWidget');
    Plugin('RT::Extension::UserProfileWidget');
    Plugin('RT::Extension::PublicHolidays');
    Plugin('RT::Extension::FeedWidget');

Also remove any C<%ReferrerComponents> entries for FeedWidget endpoints
if you added them manually — they are now set automatically.

=head1 MIGRATION FROM LocalEnhancements

If you previously loaded C<local-ticket-icons.css> via a C<MassageCSSFiles>
callback in C<LocalEnhancements>, remove that callback and the standalone CSS
file — this extension replaces both.

The ColumnMap, ShowBasics/EndOfList and ShowDates/AfterDue callbacks previously
living under C<LocalEnhancements> are now provided by this extension under the
C<BeautifyUI> namespace. Remove the old C<LocalEnhancements> copies to avoid
duplicate application.

=head1 UPDATING THE HOLIDAYS DATA

    /opt/rt6/local/plugins/RT-Extension-BeautifyUI/bin/rt-update-public-holidays \
        --csv /opt/rt6/local/etc/holidays-worldwide.csv

=head1 AUTHOR

Torsten Brumm

=head1 LICENSE

GNU General Public License v2

=cut

1;
