#!/usr/bin/perl

use Search::Elasticsearch;
use DBI;
use JSON;
use JSON::XS;
use Encode;
use Data::Dumper;
use Time::HiRes;
use Parallel::ForkManager;
use utf8;
use Text::Unidecode;
require("subs/all.subroutines.pl");
require("subs/sub.formatJSON.pl");

# == Initial Startup
&StartProcess;

# == Initial Options 
# The number of processes to fork
if ($args{forks}) {
  $forkMe = $args{forks};
} else {
  $forkMe = 5;
}

$dbh = DBI->connect("dbi:mysql:$conf{dbName}","$conf{dbUser}","$conf{dbPass}") || die "DBI Connection Error: $DBI::errstr\n";

# Access the database to build a lookup table of threadid information so that we don't waste
# time pulling this on an item-by-item basis.

&d("Building Thread/Account Lookup Table...\n");
my %sellerHash = %{$dbh->selectall_hashref("select `threadid`,`sellerAccount`,`sellerIGN`,`generatedWith`,`threadTitle` FROM `thread-last-update`","threadid")};

# The base query feeding this process will vary depending on the arguments given on the
# command line. Valid arguments currently include:
#   full - does a full update of everything
#   timestamp ###### - where ##### is an epoch timestamp, pulls all items newer than this
#   max #### - does a max of #### in one run, ignores if they are inES or not
if ($args{full}) {
  &d("!! WARNING: FULL UPDATE SPECIFIED! All previously indexed items will be scanned and re-indexed.\n");
  print localtime()." Selecting items from items\n";
  $pquery = "select `uuid` from `items` where `inES`=\"yes\"";
  $cquery = "select count(`uuid`) from `items` where `inES`=\"yes\"";
} elsif ($args{timestamp}) {
  &d("Selecting items updated since $ARGV[1]\n");
  $pquery = "select `uuid` from `items` where `updated`>$args{timestamp}";
  $cquery = "select count(`uuid`) from `items` where `updated`>$args{timestamp}";
} elsif ($args{max}) {
  &d("[Selecting a max of $args{max}]\n");
  $pquery = "select `uuid` from `items` LIMIT $args{max}";
  $updateCount = $args{max};
} else {
  $pquery = "select `uuid` from `items` where `inES`=\"no\"";
  $cquery = "select count(`uuid`) from `items` where `inES`=\"no\"";
}

# Get a count of how many items we will process if it wasn't set by max
unless ($updateCount) {
  $updateCount = $dbh->selectrow_array("$cquery");
}

if ($updateCount < 1) {
  &d("!! No new uuid's to process! Aborting run.\n");
  $dbh->disconnect;
  &ExitProcess;
}

# If this is a small update, override the number of forks to something that isn't wasteful
# (we shouldn't be processing less than 10k items per fork
my $maxForkCheck = int($updateCount / 10000) + 1;

if ($maxForkCheck < $forkMe) {
  $forkMe = $maxForkCheck;
  &d(" > Overriding forks of threads to a max of $forkMe as update is small!\n");
}

# This is a little weird/clumsy. Basically, we are going to create a hash of uuid's for each
# fork to process, with the total number split across all the forks. So, to start with, we take
# the total number of items to be updated and divide them by the number of forks to see the max
# uuid's each fork should process.
$maxInHash = int($updateCount / $forkMe) + 1;

&d(" > $updateCount uuid's to be updated [$forkMe fork(s), $maxInHash per fork]\n");

$t0 = [Time::HiRes::gettimeofday];
&d("Preparing update hash:\n");
$query_handle=$dbh->prepare($pquery);
$query_handle->{"mysql_use_result"} = 1;
$query_handle->execute();
$query_handle->bind_columns(undef, \$uuid);

# Keeps track of our active fork ID's
$forkID = 1;
# For tracking our iterations through the query
my $ucount = 0;

# Basically, iterate through the select by uuid, and add all uuid's to a hash table for
# the forkID until the count exceeds maxInHash, then increment the forkID
while($query_handle->fetch()) {
  $ucount++;
  if ($ucount > $maxInHash) {
    $forkID++;
    $ucount = 0;
  }
  $uhash{"$forkID"}{"$uuid"} = 1;
}

$dbh->disconnect;
$endelapsed = Time::HiRes::tv_interval ( $t0, [Time::HiRes::gettimeofday]);
&d(" > Update hash built in $endelapsed seconds.\n");

# Prepare forkmanager
my $manager = new Parallel::ForkManager( $forkMe );
&d("Processing started! This may take awhile...\n");

# For each forkID in our hash of UUID's, fork a process and go!
foreach $forkID (keys(%uhash)) {

  $manager->start and next;
  $dbh = DBI->connect("dbi:mysql:$conf{dbName}","$conf{dbUser}","$conf{dbPass}") || die "DBI Connection Error: $DBI::errstr\n";

  my $e = Search::Elasticsearch->new(
    cxn_pool => 'Sniff',
    nodes =>  [
      "$conf{esHost}:9200",
      "$conf{esHost2}:9200"
    ],
    # enable this for debug but BE CAREFUL it will create huge log files super fast
    # trace_to => ['File','/tmp/eslog.txt'],

    # Huge request timeout for bulk indexing
    request_timeout => 300
  );

  die "some error?"  unless ($e);
  
  my $bulk = $e->bulk_helper(
    index => "$conf{esItemIndex}",
    max_count => '5100',
    max_size => '0',
    type => "$conf{esItemType}",
  );

  $t0 = [Time::HiRes::gettimeofday];

  foreach $uuid (keys(%{$uhash{$forkID}})) {
    my @datarow = $dbh->selectrow_array("select * from `items` where `uuid`=\"$uuid\" limit 1");
    my $uuid = $datarow[0];
    my $threadid = $datarow[1];
    my $md5sum = $datarow[2];
    my $added = $datarow[3];
    my $updated = $datarow[4];
    my $modified = $datarow[5];
    my $currency = $datarow[6];
    my $amount = $datarow[7];
    my $verified = $datarow[8];
    my $priceChanges = $datarow[9];
    my $lastUpdateDB = $datarow[10];
    my $chaosEquiv = $datarow[11];
    my $inES = $datarow[12];
    my $saleType = $datarow[13];

    no autovivification;
    local %item;

    if ($sellerHash{$threadid}{threadTitle}) {
      $item{shop}{threadTitle} = $sellerHash{$threadid}{threadTitle};
    } else {
      my $threadTitle = $dbh->selectrow_array("select `title` from `web-post-track` where `threadid`=\"$threadid\"");
      if ($threadTitle) {
        $item{shop}{threadTitle} = $threadTitle;
      } else {
        $item{shop}{threadTitle} = "Unknown";
      } 
    }
    # Decode unicode in threadTitle
    $item{shop}{threadTitle} = unidecode($item{shop}{threadTitle});

    $item{uuid} = $uuid;
    $item{md5sum} = $md5sum;
    $item{shop}{threadid} = "$threadid";
    $item{shop}{added} += $added * 1000;
    $item{shop}{updated} += $updated * 1000;
    $item{shop}{modified} += $modified * 1000;
    $item{shop}{currency} = $currency;
    $item{shop}{amount} += $amount;
    $item{shop}{verified} = $verified;
    $item{shop}{priceChanges} += $priceChanges;
    $item{shop}{lastUpdateDB} = $lastUpdateDB;
    $item{shop}{chaosEquiv} += $chaosEquiv;
    $item{shop}{sellerAccount} = $sellerHash{$threadid}{sellerAccount};
    $item{shop}{sellerIGN} = $sellerHash{$threadid}{sellerIGN};
    $item{shop}{generatedWith} = $sellerHash{$threadid}{generatedWith} if ($sellerHash{$threadid}{generatedWith});
    $item{shop}{saleType} = $saleType;

    my $rawjson = $dbh->selectrow_array("select `data` from `raw-json` where `md5sum`=\"$md5sum\" limit 1");
    unless ($rawjson) {
      print "[$forkID] WARNING: $md5sum returned no data from raw json db!\n";
      next;
    }
    my $jsonout = &formatJSON("$rawjson");
    # If we got a FAIL rejection, don't load it into the ES index
    if ($jsonout =~ /^FAIL/) {
      print "ERROR: $item{uuid} $jsonout\n";
      push @changeFlagInDB, "$uuid";
      next;
    }

    # If the item is a Quest Item but not a Divination card, don't load it into the ES index
    if ($item{attributes}{rarity} eq "Quest Item") {
      push @changeFlagInDB, "$uuid";
      next;
    }

    # Skip if the item is otherwise Unknown, but log and alert
    if ($item{attributes}{baseItemType} eq "Unknown") {
      &d("WARNING: item with uuid $item{uuid} ($item{info}{fullName} has an Unknown baseItemType! This item will not be loaded. Please fix.\n");
      $dbh->do("INSERT IGNORE INTO `log-unknown` SET
                `uuid`=\"$item{uuid}\",
                `timestamp`=\"$startTime\",
                `md5sum`=\"$item{md5sum}\",
                `fullName`=\"$item{info}{fullName}\"
                ") || die "SQL ERROR: $DBI::errstr\n";
      next;
    }


    $count++;

  # Some debugging stuff 
  # Pretty Version Output
#    my $jsonchunk = JSON->new->utf8;
#    my $prettychunk = $jsonchunk->pretty->encode(\%item);
#    print "$prettychunk\n";
#    last if ($count > 5);
  

    $bulk->index({ id => "$uuid", source => "$jsonout" });
    push @changeFlagInDB, "$uuid";
 
    # We go ahead and bulk flush then update the DB at 5000 manually so we can give some output
    # for anyone watching 
    if ($count % 5000 == 0) {
      &sv("[$forkID] [$count] Bulk Flushing Data to Elastic Search:\n");
      $bulk->flush;
      &sv("[$forkID] [$count] -> Bulk Flush Completed\n");
      &sv("[$forkID] [$count]  Marking items as imported in DB:\n");
      foreach $updateuuid (@changeFlagInDB) {
        $dbh->do("UPDATE \`items\` SET inES=\"yes\" WHERE uuid=\"$updateuuid\"");
      }
      &sv("[$forkID] [$count] -> Database update completed...\n");
      $endelapsed = Time::HiRes::tv_interval ( $t0, [Time::HiRes::gettimeofday]);
      &d("[$forkID] [$count] Bulk Processed in $endelapsed seconds\n");
      $t0 = [Time::HiRes::gettimeofday];
      undef @changeFlagInDB;
    }
  
  }

  # Flush the leftover items - I'm lazy and just copy/pasted, should probably make this a subroutine 
  &sv("[$forkID] [$count] Bulk Flushing Data to Elastic Search:\n"); 
  $bulk->flush;
  &sv("[$forkID] [$count] -> Bulk Flush Completed\n");
  &sv("[$forkID] [$count]  Marking items as imported in DB:\n");
  foreach $updateuuid (@changeFlagInDB) {
    $dbh->do("UPDATE \`items\` SET inES=\"yes\" WHERE uuid=\"$updateuuid\"");
  }
  &sv("[$forkID] [$count] -> Database update completed...\n");
  $endelapsed = Time::HiRes::tv_interval ( $t0, [Time::HiRes::gettimeofday]);
  &d("[$forkID] [$count] Bulk Processed in $endelapsed seconds\n");
  undef @changeFlagInDB;
  
  &d("[$forkID] Elastic Search import complete!\n");
  
  $dbh->disconnect;
  $manager->finish;
}
$manager->wait_all_children;
&d("All processing children have completed their work!\n");

# == Exit cleanly
&ExitProcess;
