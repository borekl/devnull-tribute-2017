# /dev/null/nethack Tribute 2017

Scoreboard for the Devnull Tribute 2017 tournament.

In September 2017 the /dev/null/nethack organizer Krystal
announced that he is retiring the long running tournament.  A group of
players from Team Splat decided to run "Tribute" tournament in its place
in November 2017 as a quick way to have a replacement tournament.  This
code implements scoreboard that is supposed to imitiate the structure of
the original tournament.

---

## CONFIGURATION

The statistics generation script is configured using JSON file `dnt.conf`
that is expected to be in the current directory.  Following keys are
required:

`time`

This section is used to constrain by time what entries are accepted into
the scoreboard. The values are in unix epoch format.

* `starttime` - every accepted row must have starttime greater or equal
* `endtime` - every accepted row must have endtime smaller

`sources`

Definition of sources of information fed into the scoreboard. The keys
supported in this tree are:

* `xlogfile` - required - defines local file as xlogfile, it is supposed to be synced by means of wget etc.
* `display` - required - display name
* `ip` - optional - IP address/hostname to be used for determination whether the server is reachable
* `dumplog` - optional - URL of dumplogs

`clandb`

Path to clans database in SQLite format.

`xlogfile`

List of fields that will be used for coalesced xlogfile (see the
`--coalesce` command-line option).


## COMMAND-LINE OPTIONS

`--debug`  
This causes the scoreboard script to output file `debug.scoreboard.PID`
that contains entire `%s` structure in JSON format.

`--[no]ping`  
Disable (default is enabled) the pinging of the source servers.

`--trophies[=FILENAME]`  
This makes the scoreboard script save `%s`.`trophies`.`brief` subtree.
Default filename is `trophies.json`, but you can specify your own

`--coalesce=FILENAME`  
This makes the scoreboard to write out coalesced xlogfile that combines
rows from all sources. This is useful for making single tournament
xlogfile available in the same way as the original /dev/null/nethack. Fields
and their order is defined by `xlogfile` configuration key.


## HOW IT WORKS

The script reads the xlogfile and other supporting data sources into memory
and compiles in-memory scoreboard structure that is then passed into HTML
templates that are used to generate actual static website. The in-memory
scoreboard is held as a tree with its top level held in the `%s` hash. The
in-memory data structure has following top-level keys:

* `cfg` - copy of the configuration file; the unique subtree is removed from it, though
* `games` - games information
* `clans` - clan info
* `players` - player info
* `trophies` - trophies info

### games

`%s`.`games`.`data`.`all`  
This is list of parsed xlogfile rows, ie. list of all games played in the
tournament. All other game lists only contain indexes in this list.

`%s`.`games`.`data`.`ascended`  
List of all ascended games in chronological order.

`%s`.`games`.`data`.`asc_by_turns`  
`%s`.`games`.`data`.`asc_by_duration`  
`%s`.`games`.`data`.`asc_by_maxscore`    
`%s`.`games`.`data`.`asc_by_minscore`    
`%s`.`games`.`data`.`asc_by_conducts`  
List of ascended games in different orderings.

`%s`.`games`.`data`.`games_by_exts`  
`%s`.`games`.`data`.`games_by_kills`  
List of top three games by extinctions and kills (not necessarily ascensions!).

`%s`.`games`.`data`.`top_by_role`    
Top three scores divided by roles (for the minor trophies).


### players

`%s`.`players`.`meta`.`ord_by_ascs`  
`%s`.`players`.`meta`.`ord_by_ascs_all`  
List of players ordered by number of ascensions (descending), ties are
broken by `endtime` field. The `ord_by_ascs_all` list includes non-ascended
games ordered by `maxlvl` field. This is for getting list of all players
in sensible ordering. 

`%s`.`players`.`data`  
This hash contains all players the scoreboard knows about. Note, that the
player listed in this does not need to have any games! If one needs to test
whether the player has at least one game and the data are fully
instantiated, checking for existence of keys like `cnt_ascensions` is a good
idea.

`%s`.`players`.`data`.`PLAYER`.`games`  
Ordered list of all player's games as they appear in the xlogfile.

`%s`.`players`.`data`.`PLAYER`.`cnt_games`  
`%s`.`players`.`data`.`PLAYER`.`cnt_ascensions`  
Number of games and ascensions.

`%s`.`players`.`data`.`PLAYER`.`cnt_asc_turns`  
Total of turns in ascending games. This can be used to break ties by ascension
ratio (but currently not used).

`%s`.`players`.`data`.`PLAYER`.`maxconducts`  
Maximum number of conducts in a single winning game. If the player does not
have winning game, this field is undefined.

`%s`.`players`.`data`.`PLAYER`.`clanpts`  
Player's clan points. This key always exists and has nothing to do with whether
the player is a clan member or not.

`%s`.`players`.`data`.`PLAYER`.`clantimeref`  
Time when the player's newest scoring entry was achieved. This key always
exists, but it is undefined if player has no scoring entries.

`%s`.`players`.`data`.`PLAYER`.`maxlvl`  
Maximum (that is deepest) achieved player dungeon level.

`%s`.`players`.`data`.`PLAYER`.`maxlvl_game`  
The game that achieved players maximum level, useful for breaking ties.

`%s`.`players`.`data`.`PLAYER`.`score`  
Player's total score accrued during the tournament.

`%s`.`players`.`data`.`PLAYER`.`unique`  
Info about player's unique games. Contains `list` that lists rows in the
accept filter list and `when` with `endtime` of last unique death.

`%s`.`players`.`data`.`PLAYER`.`last_asc`  
Player's last ascension, undefined if there's none. Useful for breaking ties
by last ascensions's `endtime`.

`%s`.`players`.`data`.`PLAYER`.`scoring`  
Clan points scoring breakdown. This is an ordered list of scoring entries,
each trophy has one entry of three items: `0` is trophy name, `1` is point
value and `3` is additional information in the form of a hash for the trophy,
where relevant. Currently this gives challenge name (key `challenge`) for
challenge trophies and role (key `role`) for minor trophies.

`%s`.`players`.`data`.`PLAYER`.`challenges`  
This hash contains status info about devnull challenges. Each challenge present
has two keys: `status` and `when`. `status` is `accept`, `ignore` or `success`.
If the challenge key is not present at all, then player has not accepted nor
permanently ignored the challenge.

`%s`.`players`.`data`.`PLAYER`.`best13`  
Player's Best of 13 trophy status. This hash has three keys: `games`, `cnt`
and `when`. `games` is a list of qualifying games, `cnt` is their count and
`when` is `endtime` of the last game.


### trophies

`%s`.`trophies`.`unique`  
List of players ordered by unique deaths (in descending order).

`%s`.`trophies`.`recognition`  
Gives lists of players who achieved given trophy.

`%s`.`trophies`.`best13`  
List of players ordered by Best of 13 trophy criteria.

`%s`.`trophies`.`challenges`  
For each challenge gives list of players who completed it.

`%s`.`trophies`.`bestinshow`  
List of clans ordered by their score.

`%s`.`trophies`.`brief`.`TROPHY`
This contains terse recapitulation of actual trophy holders. The values are
either single player name (for Best of 13, Most Ascensions etc.), list
of player names (for the Recognition Trophies and Challenges) or
role->player hash for Minor Trophies.

### clans

`%s`.`clans`.`CLAN`.`members`  
`%s`.`clans`.`CLAN`.`admins`  
List of clan members (including admins) and admins.

`%s`.`clans`.`CLAN`.`cnt_games`  
Number of clan games.

`%s`.`clans`.`CLAN`.`games`  
List of last 10 clan games.

`%s`.`clans`.`CLAN`.`ascensions`  
List of clan ascensions.

`%s`.`clans`.`CLAN`.`bestinshow`.`breakdown`  
Breakdown list of clan scoring. `0` member name, `1` trophy name, `2`
points, `4` additional info where relevant or undefined

`%s`.`clans`.`CLAN`.`bestinshow`.`score`  
Total clan score.

`%s`.`clans`.`CLAN`.`bestinshow`.`scoretimeref`  
Time when the score was achieved (ie. time of the last scoring entry). This
can be undefined if the clan has not scored yet.

`%s`.`clans`.`CLAN`.`bestinshow`.`rank`  
Clans ranking on the Best In Show ladder. This key only exist for scoring
clans.

### aux

`%s`.`aux`.`time`  
`%s`.`aux`.`timefmt`  
Time when the scoreboard finished compiling in epoch format and as a
formatted human-readable string.

`%s`.`aux`.`phase`  
If time constraints are configured in config, this gives `before`, `during`
or `after` depending on current time. Useful in templates to conditonally
hide some link after the tournament ends etc.
