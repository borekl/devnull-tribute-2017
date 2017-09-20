#!/usr/bin/env perl

#============================================================================
# /dev/null/nethack Tribute 2017 Statistics Generator
# """""""""""""""""""""""""""""""""""""""""""""""""""
# (c) 2017 Borek Lupomesky
#
# Scoreboard generator for /dev/null/nethack Tribute 2017. Please see README
# for documentation on how this works.
#============================================================================

use strict;
use warnings;
use utf8;

use Getopt::Long;
use JSON;
use Template;


#============================================================================
#=== definitions ============================================================
#============================================================================

my $lockfile = '/tmp/dnt-statgen.lock';



#============================================================================
#=== global variables =======================================================
#============================================================================

# configuration, parsed from external file

my $cfg;

# array of function references that are called for each xlogfile row

my @row_consumers;

# array of function references taht are called after the whole xlogfile is
# read in

my @glb_consumers;

# the complete scoreboard data are held in this variable; this is the data
# that are supplied to Template Toolkit templates for rendering the actual
# web pages; the structure is described in the README.md

my %s;



#============================================================================
#=== stuff to do at startup =================================================
#============================================================================

BEGIN
{
  my $js = new JSON->relaxed(1);
  local $/;

  #--- read configuration file

  open(my $fh, '<', 'dnt.conf') or die 'Failed to open configuration file';
  my $config = <$fh>;
  close($fh);
  $cfg = $js->decode($config);
}



#============================================================================
#=== functions ==============================================================
#============================================================================

#============================================================================
# Split a line along field separator, parse it into hash and return it as
# a hashref.
#============================================================================

sub parse_log
{
  my $l = shift;
  my %l;
  my (@a1, @a2, $a0);

  #--- there are two field separators in use: comma and horizontal tab;
  #--- we use simple heuristics to find out the one that is used for given
  #--- xlogfile row

  @a1 = split(/:/, $l);
  @a2 = split(/\t/, $l);
  $a0 = scalar(@a1) > scalar(@a2) ? \@a1 : \@a2;

  #--- split keys and values

  for my $field (@$a0) {
    my ($key, $val) = split(/=/, $field);
    $l{$key} = $val;
  }

  #--- finish returning hashref

  return \%l
}


#============================================================================
# Display usage summary
#============================================================================

sub help
{
  print "Command-line options:\n";
  print "  --debug       debug mode\n";
  print "\n";
}



#============================================================================
#=== row consumers ==========================================================
#============================================================================

# These are functions that get to process every line of xlogfile as it's
# being read; they receive the hashref of the parsed xlogfile row as the
# argument.

#============================================================================
# Record players' games
#============================================================================

push(@row_consumers, sub
{
  my $xrow = shift;
  my $plr_name = $xrow->{'name'};

  #--- if player sub-tree or the games list do not exist, instantiate it

  if(
    !exists $s{'players'}{'data'}{$plr_name}
    || !exists $s{'players'}{'data'}{$plr_name}{'games'}
  ) {
    $s{'players'}{'data'}{$plr_name}{'games'} = [];
    $s{'players'}{'data'}{$plr_name}{'cnt_games'} = 0;
    $s{'players'}{'data'}{$plr_name}{'cnt_ascensions'} = 0;
    $s{'players'}{'data'}{$plr_name}{'cnt_asc_turns'} = 0;
  }

  #--- push new game into the list

  push(@{$s{'players'}{'data'}{$plr_name}{'games'}}, $xrow);

  #--- increment games played counter

  $s{'players'}{'data'}{$plr_name}{'cnt_games'}++;

  #--- increment games ascended counter

  if($xrow->{'death'} =~ /^ascended/) {
    $s{'players'}{'data'}{$plr_name}{'cnt_ascensions'}++;
    $s{'players'}{'data'}{$plr_name}{'cnt_asc_turns'} += $xrow->{'turns'};
  }

});



#============================================================================
#=== global consumers =======================================================
#============================================================================

# These are functions that are called once the whole xlogfile is read in,
# which also means that the row consumers did their work. Note, that the
# order of their definition is important as some build on the output of the
# preceding ones.

#============================================================================
# Create list of player names ordered by number of ascensions. Ties are
# broken by ascension ratios (ie. players that took less games to achieve
# same win count are prefered).
#============================================================================

push(@glb_consumers, sub
{
  #--- shortcut for players-data subtree

  my $plr = $s{'players'}{'data'};

  #--- get list of ascending players

  my @plr_list = grep { $plr->{$_}{'cnt_ascensions'} > 0 } keys %$plr;

  #--- sort the eligible players by number of ascensions

  my @plr_ordered = sort {
    if($plr->{$b}{'cnt_ascensions'} == $plr->{$a}{'cnt_ascensions'}) {
      $plr->{$a}{'cnt_games'} <=> $plr->{$b}{'cnt_games'}
    } else {
      $plr->{$b}{'cnt_ascensions'} <=> $plr->{$a}{'cnt_ascensions'}
    }
  } @plr_list;

  #--- store the result

  $s{'players'}{'meta'}{'ord_by_ascs'} = \@plr_ordered;

});



#============================================================================
#===================  _  ====================================================
#===  _ __ ___   __ _(_)_ __  ===============================================
#=== | '_ ` _ \ / _` | | '_ \  ==============================================
#=== | | | | | | (_| | | | | | ==============================================
#=== |_| |_| |_|\__,_|_|_| |_| ==============================================
#===                           ==============================================
#============================================================================
#============================================================================

#--- process command-line options

my (
  $cmd_debug
);

if(!GetOptions(
  'debug' => \$cmd_debug,
)) {
  help();
  exit(1);
}

#--- check/create lock file

if(-f $lockfile) {
  print "Lockfile $lockfile exists, exiting.";
  exit(1);
}

open(F, '>', $lockfile) || die "Failed to create lockfile $lockfile";
print F $$, "\n";
close(F);

#--- read the xlogfile

open(my $xlog, '<', $cfg->{'xlogfile'}) or die "Could not open the xlogfile";
while(my $l = <$xlog>) {
  chomp($l);
  my $xrow = parse_log($l);
  for my $consumer (@row_consumers) {
    $consumer->($xrow);
  }
}
close($xlog);

#--- invoke global consumers

for my $consumer (@glb_consumers) {
  $consumer->();
}

#--- debug: save the compiled scoreboard data as JSON

if($cmd_debug) {
  open(JS, '>', "debug.scoreboard.$$") or die;
  print JS JSON->new->pretty(1)->encode(\%s), "\n";
  close(JS);
}

#--- find the templates

my @templates;
my $tpath = $cfg->{'templates'}{'path'} // undef;
if($tpath && -d $tpath) {
  opendir(my $dh, $tpath)
    or die "Could not scan template directory $tpath";
  @templates = grep {
    -f "$tpath/$_" && $_ ne $cfg->{'templates'}{'player'}
  } readdir($dh);
  closedir($dh);
}

#--- process the regular templates

my $tt = Template->new(
  'OUTPUT_PATH' => $cfg->{'templates'}{'html'},
  'INCLUDE_PATH' => 'templates',
  'RELATIVE' => 1
);
for my $template (@templates) {
  my $dest_file = $template;
  $dest_file =~ s/\.tt//;
  if(!$tt->process($template, \%s, $dest_file . '.html')) {
    die $tt->error();
  }
}

#--- release lock file

unlink($lockfile);
