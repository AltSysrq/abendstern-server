# File to use for headless.tcl in the nightly^W periodic batch job.
# It requires a file name credentials to supply the username
# and password, and must be run on the database and file server
# (it directly access both to simplify things).
package require mysqltcl
source credentials
source geneticai.tcl

set ::abnet::SERVER localhost
set DATABASE abendstern
set FILES_DIR /srv/abendstern/files
::abnet::openConnection
vwait ::abnet::busy
if {!$::abnet::isReady} {
  puts stderr "Unable to connect to server: $::abnet::resultMessage"
  error batch
}

::abnet::login $USERNAME $PASSWORD
vwait ::abnet::busy
if {!$::abnet::isConnected || !$::abnet::success} {
  puts stderr "Unable to log in: $::abnet::resultMessage"
  error batch
}

# Open MySQL connection
set mcxn [::mysql::connect -host $::abnet::SERVER -user root -db $DATABASE]
# Update genetic AI
geneticai_main

# BEGIN: SHIP VALIDATION
set field [new GameField default 1 1]

set shipsToCheck [::mysql::sel $mcxn \
  "SELECT files.owner, files.fileid, ships.shipid, files.isPublic
   FROM files LEFT JOIN ships
     ON files.fileid = ships.fileid
   WHERE ships.name IS NULL
     AND files.name LIKE '%.ship'" -flatlist]

proc bad_ship {} {
  global filename mcxn fileid
  catch { $ unmodify tmpship; $ close tmpship }
  file delete $filename
  ::mysql::exec $mcxn "DELETE FROM files WHERE fileid = $fileid"
}

foreach {userid fileid shipid isPublic} $shipsToCheck {
  set filename $FILES_DIR/$userid/$fileid
  if {[catch {$ open $filename tmpship}]} {
    # Can't be opened
    log "Can't open $filename"
    bad_ship
    continue
  }

  # Try to load the ship
  if {[catch {set ship [loadShip $field tmpship]}]} {
    # Can't load
    log "Can't load ship from $filename"
    bad_ship
    continue
  }

  # Does it pass more rigorous checks?
  if {"" != [verify $ship]} {
    # Nope
    log "Unverifiable ship in $filename"
    bad_ship
    delete object $ship
    continue
  }

  # Done with the ship itself
  delete object $ship

  # Is its name sane?
  if {[catch {
    set name [$ str tmpship.info.name]
    if {$name == ""} {error empty}
    for {set i 0} {$i < [string length $name]} {incr i} {
      if {[string is control [string index $name $i]]} {
        error control
      }
    }
  }]} {
    # Bad name
    log "Bad ship name in $filename"
    bad_ship
    continue
  }

  # OK
  set name "'[::mysql::escape $name]'"
  # The ship loader already validated that class is "A", "B", or "C"
  if {"" != $shipid} {
    ::mysql::exec $mcxn \
      "UPDATE ships
       SET name = $name, class = '[$ str tmpship.info.class]',
           isPublic = $isPublic, posted = NOW()
       WHERE shipid = $shipid"
  } else {
    ::mysql::exec $mcxn \
      "INSERT INTO ships (fileid, owner, name, class, isPublic, posted)
       VALUES ($fileid, $userid, $name, '[$ str tmpship.info.class]', $isPublic, NOW())"
  }

  $ unmodify tmpship
  $ close tmpship
  log "Good ship in $filename"
}

delete object $field
# END: SHIP VALIDATION

# Update indices
set ::abnet::busy yes
set ::abnet::currentAction generic
# Give the server an additional 5 minutes
set ::abnet::lastReceive [expr {[clock seconds]+300}]
::abnet::enable action-status
::abnet::writeServer admin-update-indices
vwait ::abnet::busy

if {!$::abnet::success} {
  puts stderr "Error updating indices"
  error batch
}

# Done
::mysql::close $mcxn
::abnet::logout
after 5000
$state setReturn $state
