use strict;
use warnings;
use LWP::Simple;
use Data::Dumper;
use URL::Encode qw/url_encode/;
use Digest::MD5 qw/md5_hex/;
use Term::ANSIColor;
use Encode;
use Path::Tiny;
use DBI;
use Memoize;

memoize "get_article_id";
memoize "get_category_id";


sub debug (@);
sub dbhdo (@);

my $studied_articles = 0;

my $dbargs = {AutoCommit => 0, PrintError => 1};
my $dbh = DBI->connect(
    "dbi:SQLite:dbname=wiki.db",
    "",
    "",
    { RaiseError => 1}
) or die $DBI::errstr;

my $tmp = './.myget_cache/';

my %options = (
	debug => 0,
	start => undef,
	max_depth => 1,
	max_article => 0,
	run => 0
);

analyze_args(@ARGV);
create_db_structure();
my $sth_insert_article = $dbh->prepare("insert or ignore into article(url, name) values(?,?)");

sub debug (@) {
	if($options{debug}) {
		foreach (@_) {
			warn color("on_green black").$_.color("reset")."\n";
		}
	}
}

sub dbhdo (@) {
	foreach my $query (@_) {
		debug "dbhdo($query)";
		$dbh->do($query) or die $DBI::errstr;
	}
}

sub create_db_structure {
	my @dbs = (
		"CREATE TABLE IF NOT EXISTS category (id INTEGER PRIMARY KEY AUTOINCREMENT, name TEXT, url TEXT, UNIQUE(name, url));",
		"CREATE TABLE IF NOT EXISTS article (id INTEGER PRIMARY KEY AUTOINCREMENT, name TEXT, url TEXT, UNIQUE(name, url));",
		"CREATE TABLE IF NOT EXISTS article_to_article (article_from INTEGER, article_to INTEGER, UNIQUE(article_from, article_to));",
		"CREATE TABLE IF NOT EXISTS article_to_category (article_id INTEGER, category_id INTEGER, FOREIGN KEY(article_id) REFERENCES article(id), FOREIGN KEY (category_id) REFERENCES category(id), UNIQUE(article_id,category_id));",
		"CREATE TABLE IF NOT EXISTS article_studied (article_id INTEGER, UNIQUE(article_id));"
	);

	foreach my $db (@dbs) {
		debug $db;
		dbhdo $db;
	}
}

sub get_categories {
	my $url = shift;
	my $page = myget($url);
	if($page =~ m#<div id="catlinks" class="catlinks" data-mw="interface">(.*?)</div>#) {
		my $categories_string = $1;
		my @categories = ();
		while ($categories_string =~ m#<li><a href="/wiki/(Category:[^"]*)" title="Category:([^"]*)">[^<]*</a></li>#gism) {
			push @categories, { link => "https://en.wikipedia.org/wiki/$1", name => $2 };
		}
		return @categories;
	} else {
		die "No page under $url";
	}
}

sub get_links {
	my $url = shift;

	my $page = myget($url);
	my @links = ();

	while ($page =~ m#<a href="/wiki/([^"]*)" title="([^"]*)">.*?</a>#gism) {
		my $link = $1;
		my $name = $2;
		if($link !~ m#^(Talk|Category|Wikipedia|Template|Special|Help|Portal|File):# && $name !~ /^(Template talk):/) {
			push @links, { link => "https://en.wikipedia.org/wiki/$link", name => $name };
		}
	}
	return @links;
}

sub create_dot_file {
	my $filename = $options{start}.".dot";
	if(-e $filename) {
		unlink $filename;
	}

	debug "Starting .dot-file query";
	my $query = "select cat_a.name, cat_b.name from article_to_article art_art join article art_a on art_a.id = art_art.article_from join article art_b on art_b.id = art_art.article_to join article_to_category art_cat_a on art_cat_a.article_id = art_art.article_from join article_to_category art_cat_b on art_cat_b.article_id = art_art.article_from join category cat_a on cat_a.id = art_cat_a.category_id join category cat_b on cat_b.id = art_cat_b.category_id;";

	my $sth = $dbh->prepare($query);
	$sth->execute();

	open my $fh, '>>', $filename;
	print $fh "digraph a {\n";
	print $fh "\tgraph [overlap=false outputorder=edgesfirst];\n";
	print $fh "\tnode [style=filled fillcolor=white];\n";

	my %already_done = ();

	while(my @row = $sth->fetchrow_array()) {
		my ($from, $to) = @row;
		if(!defined($already_done{$from}) && !defined($already_done{$from}{$to})) {
			if($from ne $to) {
				print $fh qq#\t"$from" -> "$to";\n#;
			}
			$already_done{$from}{$to} = 1;
		}
	}
	print $fh "}\n";

	if($options{run}) {
		my $code = "circo -Tsvg $filename > $filename.svg && gwenview $filename.svg";
		debug $code;
		system($code);
	}
}

sub main {
	my $starturl = "https://en.wikipedia.org/wiki/".$options{start};

	study_site($starturl, $options{start});

	create_dot_file();
}

sub get_category_id {
	my $url = shift;
	my $r = $dbh->selectrow_array("select id from category where url = ?", undef, $url);
	debug "get_category_id($url) = $r";
	return $r;
}

sub get_article_id {
	my $url = shift;
	my $r = $dbh->selectrow_array("select id from article where url = ?", undef, $url);
	debug "get_article_id($url) = $r";
	return $r;
}

sub save_article {
	my ($url, $name) = @_;
	$sth_insert_article->execute($url, $name);
}

sub set_article_studied {
	my $article_id = shift;
	my $sth = $dbh->prepare("insert or ignore into article_studied(article_id) values(?)");
	$sth->execute($article_id);
}

sub save_data {
	my ($url, $name, $links) = @_;
	debug "!!!!!!!!!!!!!!!!!!!!!!!save_data($url, $name)";

	my @categories = get_categories($url);

	save_article($url, $name);

	my $article_id = get_article_id($url);

	set_article_studied($article_id);

	foreach my $cat (@categories) {
		my ($c_url, $c_name) = ($cat->{link}, $cat->{name});
		my $sth = $dbh->prepare("insert or ignore into category(url, name) values(?,?)");
		$sth->execute($c_url, $c_name);
		my $category_id = get_category_id($c_url);

		my $sth2 = $dbh->prepare("insert or ignore into article_to_category(article_id, category_id) values(?,?)");
		$sth2->execute($article_id, $category_id);
		debug "Saved article '$name' <-> category '$c_name' connection";
	}

	foreach my $link (@$links) {
		my ($l_url, $l_name) = ($link->{link}, $link->{name});
		save_article($l_url, $l_name);
		my $l_article_id = get_article_id($l_url);

		my $sth = $dbh->prepare("insert or ignore into article_to_article(article_from, article_to) values(?,?)");
		$sth->execute($article_id, $l_article_id);
	}
}

sub already_studied {
	my $url = shift;
	my $article_id = get_article_id($url);
	return $dbh->selectrow_array("select count(*) from article_studied where article_id = ?", undef, $url);
}

sub study_site {
	my ($url, $name, $depth) = @_;
	$studied_articles++;
	return if($options{max_article} && $studied_articles >= $options{max_article});
	return if already_studied($url);

	debug "Studying article nr. $studied_articles".($options{max_article} ? " of $options{max_article}" : "").", $url";

	if(!defined $depth) {
		$depth = 0;
	}

	if($depth > $options{max_depth}) {
		warn "Max depth reached\n";
		return;
	}

	my @links = get_links($url);

	save_data($url, $name, \@links);

	foreach (@links) {
		my $this_url = $_->{link};
		my $this_name = $_->{name};
		return if($options{max_article} && $studied_articles > $options{max_article});
		study_site($this_url, $this_name, ++$depth);
	}
}

sub analyze_args {
	for (@_) {
		if(m#^--debug$#) {
			$options{debug} = 1;
		} elsif(m#^--max_article=(\d*)$#) {
			$options{max_article} = $1;
		} elsif(m#^--max_depth=(\d*)$#) {
			$options{max_depth} = $1;
		} elsif(m#^--run$#) {
			$options{run} = 1;
		} elsif(m#^--start=(.*)$#) {
			$options{start} = $1;
		} else {
			die "Unknown parameter $_";
		}
	}
}

sub myget {
	my $url = shift;
	debug "myget($url)";
	unless (-d $tmp) {
		mkdir $tmp or die("$!");
	}

	my $cache_file = $tmp.md5_hex(Encode::encode_utf8($url));

	my $page = undef;

	if(-e $cache_file) {
		debug "`$cache_file` exists. Returning it.";
		$page = path($cache_file)->slurp;
	} else {
		debug "`$cache_file` Did not exist. Getting it...";
		$page = get($url);
		if($page) {
			open my $fh, '>', $cache_file;
			binmode($fh, ":utf8");
			print $fh $page;
			close $fh;
			debug "`$url` successfully downloaded.";
		} else {
			debug "`$url` could not be downloaded.";
		}
	}

	return $page;
}

main();
