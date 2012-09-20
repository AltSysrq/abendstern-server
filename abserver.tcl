#! /usr/bin/tclsh
#
# Implementation of server-side of Abendstern Network protocol
#
# Depends on mpzpowm and mpzrand being in PATH
# Should be run by inetd

package require Tcl 8.5
package require mysqltcl
package require aes ;#From Tcllib
package require sha256 ;#From Tcllib

# Configuration
set env(PATH) "/bin:/usr/bin:/usr/local/bin"
set DATABASE abendstern
set BLOCK_SZ 16
set DEBUG yes
set LOGFILE /var/log/abserver.log
set LOGPRIORITY 0 ;#0=info, 1=warning, 2=error, 3=none
set MINVERSION 0
set MAXVERSION 0
set DHKE_PRIME_MODULUS 444291e51b3ea5fd16673e95674b01e7b
set DHKE_BASE 5
set FILES_DIR /srv/abendstern/files
set PUBFILES_DIR /srv/abendstern/public
set WWW_GEN_DIR /srv/www/gen
set WWW_GEN_DIR_REL /gen
set WWW_PUBFILES_DIR_REL /pub
set MAX_MSG_LEN [expr {256*1024}]
set DISK_QUOTA [expr {32*1024*1024}] ;#32MB
# Maximum file size is based on glob patterns matching
# filenames
set MAX_FILE_SZ [list \
  abendstern.rc [expr {128*1024}] \
  avatar        16384 \
  *             [expr {1*1024*1024}]]
# The block size of the disk.
# User files will have their sizes rounded up to this
set FILE_BLOCK_SZ 4096
# Usernames may not start with these prefices
#   ~   Indicates local (not networked) user
#   #   Indicates computer-controlled player
#   !   Defunct user
set RESTRICTED_PREFICES [list ~ # !]

set JOB_CHECK_INTERVAL 60

# Global vars
set inputMode plain
set outputMode plain
lassign [exec getpeername] remoteAddr remotePort
set remoteUDPPort unknown

set enabledMessages [list error abendstern ping make-me-a-slave]
set isRunning yes

set dhke_secret {}
set dhke_remotepublic {}
set inputKey {}
set outputKey {}
set userid {}
set username {}
set mysqlcxn {}
set outputsSinceKeyChange 0
set isAdmin no
set diskUsage {}

set jobid {}
set jobCallback {}
set lastJobCheck [clock seconds]

set exitHooks {}

# We need to reset the lastLogin field periodically (at least
# once every 5 minutes, though we'll do 4)
# The session expires if userid is non-empty and this is
# more than 5 minutes ago
set lastLoginPing 0
set hasLoginExpired no

encoding system utf-8
set logOutput [open $LOGFILE a]

# Reads a "line" of input.
# The input may have up to BLOCK_SZ trailing linefeeds
proc rl {} {
  global inputMode inputKey
  switch $inputMode {
    plain {
      set line [gets stdin]
      if {[eof stdin]} {
        error "End-of-file"
      }
      return [encoding convertfrom utf-8 $line]
    }
    secure {
      set str {}
      while {-1 == [string first "\n" $str]} {
        set dat [read stdin $::BLOCK_SZ]
        if {[eof stdin]} {
          error "End-of-file"
        }
        append str [::aes::Decrypt $inputKey $dat]
        if {[string length $str] > $::MAX_MSG_LEN} {
          error "Message too long"
        }
      }
      return [encoding convertfrom utf-8 $str]
    }
    default {
      error "Unexpected inputMode $inputMode"
    }
  }
}

# Writes a "line" of output
# In secure mode, the output will be padded with newlines
# until it is a multiple of 16 in size
proc wl str {
  global outputMode outputKey outputsSinceKeyChange
  switch $outputMode {
    plain {
      puts $str
    }
    secure {
      incr outputsSinceKeyChange
      if {$outputsSinceKeyChange > 1024} {
        set outputsSinceKeyChange 0
        setKey outputKey [string trim [exec mpzrand]]
      }

      set str [encoding convertto utf-8 $str]
      append str "\n"
      while {[string length $str] % $::BLOCK_SZ} {
        append str "\n"
      }
      puts -nonewline [::aes::Encrypt $outputKey $str]
      flush stdout
    }
    default {
      error "Unexpected outputMode $outputMode"
    }
  }
}

# Runs the given script when exiting in any case
proc atexit args {
  global exitHooks
  set exitHooks [linsert $exitHooks 0 $args] ;#NOT {*}$args -- we want that to be a sublist
}

# Executes the given message if possible
proc execmsg {msg args} {
  global enabledMessages isAdmin
  if {0 == [string first "admin-" $msg] && !$isAdmin} {
    error "$msg requires administrative access"
  }
  foreach pattern $enabledMessages {
    if {[string match $pattern $msg]} {
      message-$msg {*}$args
      return
    }
  }
  error "Message not allowed: $msg"
}

# Enables the given message patterns
proc enable args {
  global enabledMessages
  lappend enabledMessages {*}$args
}

# Disables the given message patterns
# No error if they are not present
proc disable args {
  global enabledMessages
  foreach pattern $args {
    while {-1 != [set ix [lsearch -exact $enabledMessages $pattern]]} {
      set enabledMessages [lreplace $enabledMessages $ix $ix]
    }
  }
}

# Writes a log message at the given priority
proc log {pri msg} {
  global logOutput LOGPRIORITY remoteAddr remoteHost remotePort
  switch $pri {
    info  {set pri 0; set head INFO}
    warn  {set pri 1; set head WARN}
    error {set pri 2; set head ERRR}
  }
  if {$pri >= $LOGPRIORITY} {
    puts $logOutput [format "%s %16s:%05s %s: %s" \
                     [clock format [clock seconds] -format "%Y.%m.%d %H:%M:%S"] \
                     $remoteAddr $remotePort $head $msg]
    flush $logOutput
  }
}

# Alters the given AES key to the specified hexadecimal string
proc setKey {which key} {
  upvar $which k
  if {[string length $k]} {
    ::aes::Final $k
  }

  set k [::aes::Init cbc [binary format H32 [format %032s $key]] 0123456789ABCDEF]
}

# Converts a user name to its canonical form.
# Specifically:
#   All whitespace is removed
#   All characters are made lowercase
#   The following visually-ambiguous substitutions are made:
#     1 -> l
#     i -> l
#     0 -> o
proc canonicaliseName name {
  set cname {}
  for {set i 0} {$i < [string length $name]} {incr i} {
    set ch [string index $name $i]
    if {[string is space $ch]} continue
    set ch [string tolower $ch]
    switch -exact -- $ch {
      1 { set ch l }
      i { set ch l }
      0 { set ch o }
    }

    append cname $ch
  }

  return $cname
}

# Returns whether a username is acceptable.
# The following are the criteria:
# + Length >= 3 characters
# + Length <= 32 characters
# + No control characters
# + At least 3 letters
# Returns two-item list (l10n entry, English) on invalid,
# empty string on success
proc isNameValid name {
  if {[string length $name] < 3} {
    return [list { name too_short } "Name is too short (min 3 chars)" ]
  }
  if {[string length $name] > 32} {
    return [list { name too_long } "Name is too long (max 32 characters)" ]
  }
  set numLetters 0
  for {set i 0} {$i < [string length $name]} {incr i} {
    set ch [string index $name $i]
    if {[string is control $ch]} {
      return [list { name has_control } "Name contains control characters" ]
    }
    if {[string is alpha $ch]} {
      incr numLetters
    }
  }

  if {$numLetters < 3} {
    return [list { name insuf_alpha } "Name has too few letters (min 3)"]
  }

  set firstNonWhitespace [string index [string trim $name] 0]
  foreach forbidden $::RESTRICTED_PREFICES {
    if {$firstNonWhitespace == $forbidden} {
      return [list { name bad_prefix } "Name begins with restricted prefix"]
    }
  }

  return {}
}

# Hashes a user's password with the given salt
# (which should be the canonical username)
proc pwhash {user passwd} {
  sha2::sha256 $user$passwd
}

proc main {} {
  global exitHooks isRunning logOutput userid lastLoginPing hasLoginExpired
  log info "Greetings"
  if {[catch {
    while {$isRunning} {
      set line [rl]
      if {[string length $userid]} {
        set now [clock seconds]
        # Check for timeout (the SYSTEM account cannot time out)
        if {[clock add $lastLoginPing 5 minutes] <= $now && 0 != $userid} {
          # Expired
          wl [list error {session timeout} "The session has timed out"]
          set isRunning no
          log error "Session expired"
          set hasLoginExpired yes
        } elseif {[clock add $lastLoginPing 3 minutes] <= $now} {
          # New ping
          UPDATE accounts SET lastLogin = CURRENT_TIMESTAMP WHERE userid = $userid
          set lastLoginPing $now
        }
      }

      if {$isRunning} {
        execmsg {*}$line
      }
    }
  } err erropts]} {
    log error "Unspecified: $err"
    catch {sendError $err}

    if {$::DEBUG} {
      set debout [open /tmp/debug.log w]
      puts $debout $err
      puts $debout $erropts
      close $debout
    }
  }

  foreach script $exitHooks {
    if {[catch {eval $script} err]} {
      log error "Exit hook: $err"
    }
  }

  log info "Disconnect"
  close $logOutput
}

proc sendError msg {
  global isRunning
  wl [list error {unspecified error} $msg]
  set isRunning no
}

# Ensures the SQL connection is open
proc ensureSQLOpen {} {
  global mysqlcxn DATABASE
  if {![string length $mysqlcxn]} {
    set mysqlcxn [::mysql::connect -host localhost -user root -db $DATABASE]

    atexit ::mysql::close $mysqlcxn
  }
}

# Properly quotes the passed string, for use within SQL
proc ' str {
  return "'[::mysql::escape $str]'"
}

# Performs a SELECT and returns a list of lists corresponding to the rows
proc SELECTALL args {
  global mysqlcxn
  ensureSQLOpen
  ::mysql::sel $mysqlcxn "SELECT [join $args]" -list
}
# Performs a SELECT and returns a flat list
proc SELECTALLF args {
  global mysqlcxn
  ensureSQLOpen
  ::mysql::sel $mysqlcxn "SELECT [join $args]" -flatlist
}

# Runs SELECT and expects a single row.
# If exactly one row is returned, the given variables
# in the caller are set and true is returned; otherwise,
# false is returned
proc SELECTR {what args} {
  set rows [SELECTALL [join $what ,] {*}$args]
  if {1 != [llength $rows]} {
    return no
  }
  set row [lindex $rows 0]
  uplevel [list lassign $row {*}$what]
  return yes
}

# Like SELECTR, but what alternates between SQL names and
# Tcl variables
proc SELECTRA {what args} {
  set sqlargs {}
  set tclvars {}
  foreach {s t} $what {
    lappend sqlargs $s
    lappend tclvars $t
  }
  if {[SELECTR $sqlargs {*}$args]} {
    foreach var $tclvars sql $sqlargs {
      uplevel [list set $var [set $sql]]
    }
    return 1
  } else {
    return 0
  }
}

proc DELETE args {
  global mysqlcxn
  ensureSQLOpen

  # Prevent common errors by forbidding DELETE FROM table;
  if {-1 == [lsearch -exact -nocase $args WHERE]} {
    error "SQL DELETE command without WHERE clause (DELETE [join $args])"
  }

  ::mysql::exec $mysqlcxn "DELETE [join $args]"
}

proc INSERT args {
  global mysqlcxn
  ensureSQLOpen
  ::mysql::exec $mysqlcxn "INSERT [join $args]"
}

proc UPDATE args {
  global mysqlcxn
  ensureSQLOpen
  ::mysql::exec $mysqlcxn "UPDATE [join $args]"
}

# Runs the internal code in a transaction.
# If an error is thrown, the transaction is rolled back;
# otherwise, it is comitted.
# A break causes a rollback, but otherwise results in
# linear code flow.
proc TRANSACTION code {
  global mysqlcxn
  ensureSQLOpen
  ::mysql::exec $mysqlcxn "START TRANSACTION"
  set code [catch {
    uplevel 1 $code
  } result options]
  if {1 == [dict get $options -level] || 0 != $code} {
    # Error
    ::mysql::exec $mysqlcxn "ROLLBACK"
  } else {
    # OK
    ::mysql::exec $mysqlcxn "COMMIT"
  }

  if {$code == 2} {
    return -code 2 $result
  } elseif {$code == 3} {
    # Break
    return $result
  } else {
    return {*}$options $result
  }
}

# Ensures that the given string is a valid integer for SQL.
# If it is not, an error is raised
proc assert_integer str {
  if {![string is ascii -strict $str] || ![string is digit -strict $str]} {
    error "Integer expected"
  }
}

# Ensures that the given string is a valid float for SQL.
proc assert_float str {
  if {![string is double -strict $str]} {
    error "Float expected"
  }
}

# Same as assert_integer, but allows signed strings
proc assert_signed_integer str {
  if {[string index $str 0] == "-"} {
    assert_integer [string range $str 1 end]
  } else {
    assert_integer $str
  }
}

# Ensures that the given string is a valid boolean (0 or 1) for SQL.
# Any Tcl boolean is accepted; the caller's variable will be modified
# accordingly
proc assert_boolean str {
  upvar $str b
  if {[string is boolean $b]} {
    # Force to 0 or 1
    set b [expr {!!$b}]
  } else {
    error "Boolean expected"
  }
}

# Converts a date as returned by MySQL to a clock integer
proc dateToClock date {
  clock scan $date -format "%Y-%m-%d %H:%M:%S"
}
# Converts a clock integer to a MySQL date
proc clockToDate clock {
  clock format $clock -format "%Y-%m-%d %H:%M:%S"
}

# Converts a raw byte count into an effective disk size.
# Zero will be considered to be one block (to prevent
# creating an infinite number of empty files); everything
# else is just rounded up
proc effectiveSize sz {
  global FILE_BLOCK_SZ
  if {$sz == 0} {
    return $FILE_BLOCK_SZ
  } else {
    return [expr {($sz+$FILE_BLOCK_SZ-1)/$FILE_BLOCK_SZ*$FILE_BLOCK_SZ}]
  }
}

proc message-ping {} {
  # Assign a job if logged in, there is no current job, and we haven't checked
  # for a job in the last minute.
  set now [clock seconds]
  if {$::userid ne {} && $::jobid eq {} &&
      $now > $::lastJobCheck+$::JOB_CHECK_INTERVAL &&
      $::REMOTE_EXACT_VERSION > 20120721212256} {
    set ::lastJobCheck $now
    TRANSACTION {
      if {[SELECTRA {jobs.id id jobs.job job} \
           FROM jobs \
           LEFT JOIN jobFailures \
           ON jobs.id = jobFailures.job \
           AND jobFailures.user = $::userid \
           WHERE jobs.startedAt IS NULL \
           AND jobFailures.id IS NULL \
           LIMIT 1 \
           FOR UPDATE]} {
        UPDATE jobs SET startedAt = $now WHERE id = $id
        set ::jobid $id
        set ::jobCallback "job-done-[lindex $job 0]"
        enable job-done job-failed
        log info "Assigning job $::jobid"
        wl [list job {*}$job]
      }
    }
  }
}

proc message-error {l10n msg} {
  global isRunning
  log error "Client error: $l10n: $msg"
}

proc message-abendstern {netwvers longvers} {
  global MINVERSION MAXVERSION isRunning
  if {![string is wideinteger -strict $netwvers] ||
      ![string is wideinteger -strict $longvers]} {
    log info "Rejecting invalid version combo $netwvers/$longvers"
    sendError "Bad version"
    return
  }
  if {$netwvers < $MINVERSION || $netwvers > $MAXVERSION} {
    log info "Rejecting incompatible version $netwvers/$longvers"
    sendError "Incompatible version $netwvers"
    return
  }

  set ::REMOTE_PROTOCOL_VERSION $netwvers
  set ::REMOTE_EXACT_VERSION $longvers

  log info "Accepting connection, version $netwvers/$longvers"
  wl [list abendstern $MAXVERSION]
  disable abendstern
  enable dhke-first

  # Clients later than 20111109 understand clock-sync
  if {$longvers > 20111109000000} {
    wl [list clock-sync [clock seconds]]
  }
}

proc message-dhke-first A {
  global dhke_remotepublic dhke_secret DHKE_BASE DHKE_PRIME_MODULUS
  set dhke_remotepublic $A

  set b [string trim [exec mpzrand]]
  # Calculate base**A**B
  set result [string trim [exec mpzpowm $A $b $DHKE_PRIME_MODULUS]]
  # Pad with zeroes if needed
  set result [format %032s $result]
  # Take lowest 128 bits
  set dhke_secret [string range $result end-31 end]

  # Generate reply
  wl [list dhke-second [string trim [exec mpzpowm $DHKE_BASE $b $DHKE_PRIME_MODULUS]]]

  disable dhke-first
  enable begin-secure
}

proc message-begin-secure {} {
  global inputMode outputMode inputKey outputKey dhke_secret
  set inputMode secure
  set outputMode secure
  setKey inputKey $dhke_secret
  setKey outputKey $dhke_secret

  enable change-key pre-*

  fconfigure stdin  -buffering none -translation binary
  fconfigure stdout -buffering none -translation binary
}

proc message-change-key key {
  global inputKey
  setKey inputKey $key
}

proc message-pre-account-login {user passwd} {
  set err [isNameValid $user]
  if {[llength $err]} {
    # Bad name, don't even bother processing
    wl [list action-status 0 {*}$err]
    log warn "Reject name $user"
    return
  }

  set iuname [canonicaliseName $user]
  set pwhash [pwhash $iuname $passwd]

  TRANSACTION {
    set found [SELECTR [list userid isLoggedIn lastLogin isAdmin] \
               FROM accounts WHERE name = [' $iuname] AND passwd = '$pwhash' \
               FOR UPDATE]
    if {!$found} {
      # Name/pw combo not found
      log warn "Failed login for user $user"
      # Delay for three seconds. Since this is in a transaction, it
      # should block any further attempts until this returns
      after 3000
      wl [list action-status 0 { login failed } "Username/password combination not found"]
      return
    }

    if {$isLoggedIn} {
      set lastLogin [dateToClock $lastLogin]
      if {[clock seconds] < [clock add $lastLogin 5 minutes]} {
        # Already logged in elsewhere
        # We don't need to delay, since this isn't an invalid credentials
        # error
        log warn "Duplicate login for user $user"
        wl [list action-status 0 { login already } "Account in use; perhaps try waiting a few minutes"]
        return
      }
    }

    # Success
    UPDATE accounts \
    SET isLoggedIn = 1, lastLogin = CURRENT_TIMESTAMP, friendlyName = [' $user] \
    WHERE userid = $userid
  }

  wl [list user-id $userid]
  wl [list action-status 1 { general success } "The operation completed successfully" ]

  set ::userid $userid
  set ::username $user
  set ::lastLoginPing [clock seconds]
  set ::isAdmin $isAdmin
  if {$isAdmin} {
    enable admin-*
  }
  # Find out their current disk usage.
  # Round each file up to the next 4096-byte block
  SELECTRA [list {SUM((size+4095)DIV(4096)*4096)} totalSize] FROM files WHERE owner = $userid
  # MySQL returns the sum of an empty set as NULL...
  if {$totalSize != "NULL" && $totalSize != ""} {
    set ::diskUsage $totalSize
  } else {
    set ::diskUsage 0
  }

  atexit {*}{
    if {!$::hasLoginExpired} {
      UPDATE accounts SET isLoggedIn = 0 WHERE userid = $::userid
    }
  }

  log info "Login success for user $user"

  disable pre-*
  enable top-*
}

proc message-pre-account-create { user passwd } {
  global FILES_DIR
  set err [isNameValid $user]
  if {[llength $err]} {
    wl [list action-status 0 {*}$err]
    log warn "Rejecting invalid username $user"
    return
  }

  set iuname [canonicaliseName $user]

  TRANSACTION {
    # See if it's a duplicate
    set existing [SELECTALL name FROM accounts WHERE name = '$iuname' FOR UPDATE]
    if {[llength $existing]} {
      wl [list action-status 0 { name duplicate } "The given name is already in use"]
      log warn "Rejecting duplicate username $user"
      return
    }

    # OK, create and log in
    INSERT INTO accounts (name, friendlyName, passwd, isLoggedIn) \
    VALUES ([' $iuname], [' $user], '[pwhash $iuname $passwd]', 1)

    SELECTR userid FROM accounts WHERE name = [' $iuname]
  }

  # Subscribe the user to the defaults (SYSTEM, me, them)
  INSERT INTO userSubscriptions (subscriber, subscribee) \
  VALUES ($userid, 0), ($userid, 1), ($userid, $userid)

  wl [list user-id $userid]
  wl [list action-status 1 { general success } "The operation completed successfully"]
  file mkdir $FILES_DIR/$userid

  set ::userid $userid
  set ::username $user
  set ::lastLoginPing [clock seconds]
  set ::diskUsage 0

  atexit {*}{
    if {!$::hasLoginExpired} {
      UPDATE accounts SET isLoggedIn = 0 WHERE userid = $::userid
    }
  }

  log info "Account creation success for user $user"

  disable pre-*
  enable top-*
}

proc message-top-get-subscriber-info {} {
  set ui [SELECTALLF subscribee \
          FROM userSubscriptions \
          WHERE subscriber = $::userid]
  set si [SELECTALLF subscribee \
          FROM shipSubscriptions \
          WHERE subscriber = $::userid]
  wl [list subscriber-info $ui $si]
}

proc message-top-subscribe-user userid {
  assert_integer $userid
  catch {
    INSERT INTO userSubscriptions (subscriber, subscribee) \
    VALUES ($::userid, $userid)
  }
}

proc message-top-subscribe-ship shipid {
  assert_integer $shipid
  catch {
    INSERT INTO shipSubscriptions (subscriber, subscribee) \
    VALUES ($::userid, $shipid)
  }
}

proc message-top-unsubscribe-user userid {
  assert_integer $userid
  DELETE FROM userSubscriptions \
  WHERE subscriber = $::userid AND subscribee = $userid
}

proc message-top-unsubscribe-ship shipid {
  assert_integer $shipid
  DELETE FROM shipSubscriptions \
  WHERE subscriber = $::userid AND subscribee = $shipid
}

proc message-top-account-logout {} {
  global isRunning
  set isRunning no
  # atexit scripts will do the rest
}

proc message-top-account-rename {newname newpasswd} {
  global userid username
  set err [isNameValid $newname]
  if {[llength $err]} {
    wl [list action-status 0 {*}$err]
    log warn "Rejecting invalid name change from $username to $newname"
    return
  }

  set iuname [canonicaliseName $newname]
  TRANSACTION {
    set existing [
      SELECTALL name FROM accounts \
      WHERE userid != $userid AND name = [' $iuname] \
      FOR UPDATE]

    if {[llength $existing]} {
      wl [list action-status 0 { name duplicate } "The given name is already in use"]
      log warn "Rejecting rename from $username to duplicate $newname"
      return
    }

    # OK
    UPDATE accounts \
    SET name = [' $iuname], passwd = '[pwhash $iuname $newpasswd]' \
    WHERE userid = $userid
  }

  log info "Rename $username to $newname"
  set username $newname

  wl [list action-status 1 { general success } "The operation completed successfully"]
}

proc message-top-account-delete {} {
  global isRunning userid FILES_DIR
  log info "Delete user $username"
  DELETE FROM accounts WHERE userid = $userid
  file delete -force $FILES_DIR/$userid
}

proc message-top-file-lookup {userid filename} {
  set fileid {} ;# Return empty fileid if not found
  assert_integer $userid
  SELECTR fileid FROM files WHERE owner = $userid AND name = [' $filename]
  wl [list fileid $userid $filename $fileid]
}

# The stat message is also used by open;
# returns the userid and size of the file on success,
# or an empty string otherwise.
#
# If this is run within a transaction, it will lock the row from writing
# (prevnting synchronisation issues relating to replacing the file)
proc message-top-file-stat fileid {
  assert_integer $fileid
  if {[SELECTR [list owner size lastModified isPublic] FROM files \
       WHERE fileid = $fileid LOCK IN SHARE MODE]} {
    if {$owner == $::userid || $isPublic} {
      log info "stat $fileid"
      wl [list file-info $fileid $size [dateToClock $lastModified]]
      return [list $owner $size]
    } else {
      log warn "access denied to $fileid"
    }
  } else {
    log warn "bad fileid: $fileid"
  }
  # Non-existent or forbidden
  wl [list file-info $fileid {} {}]
  return {}
}

proc message-top-file-open fileid {
  global FILES_DIR

  set success no

  # By doing the below in a transaction, we will prevent writes
  # to that row, which will prevent the file from being replaced
  # until we have opened its inode
  TRANSACTION {
    lassign [message-top-file-stat $fileid] owner size
    if {"" != $owner} {
      set file [open $FILES_DIR/$owner/$fileid rb]
      set success yes
    }
  }
  if {$success} {
    log info "get $fileid"
    fcopy $file stdout
    close $file
  }
}

proc message-top-post-file {name newsize isPublic} {
  global MAX_FILE_SZ DISK_QUOTA FILES_DIR userid diskUsage
  assert_integer $newsize
  assert_boolean isPublic

  if {$name == ""} {
    # Blank name
    # Skip the incomming data
    set blackhole [open /dev/null w]
    fcopy stdin $blackhole -size $newsize
    close $blackhole
    # Return failure
    log warn "Bad file name"
    wl [list action-status no {file refused} "The server refused to work with the given file"]
    return
  }

  # Make sure the string is non-controll ASCII only, since
  # we may print the name to our log
  for {set i 0} {$i < [string length $name]} {incr i} {
    set ch [string index $name $i]
    if {![string is ascii $ch] || [string is control $ch]} {
      # Bad name
      # Skip the incomming data
      set blackhole [open /dev/null w]
      fcopy stdin $blackhole -size $newsize
      close $blackhole
      # Return failure
      log warn "Bad file name"
      wl [list action-status no {file refused} "The server refused to work with the given file"]
      return
    }
  }

  # Find the maximum size for this file
  foreach {pattern sz} $MAX_FILE_SZ {
    if {[string match $pattern $name]} {
      set maxSize $sz
      break
    }
  }

  # SYSTEM has no limit, but other users do
  if {$newsize > $maxSize && $::userid != 0} {
    # Skip the incomming data
    set blackhole [open /dev/null w]
    fcopy stdin $blackhole -size $newsize
    close $blackhole

    # Return failure
    log warn "File size $newsize too large"
    wl [list action-status no {file refused} "The server refused to work with the given file"]
    return
  }

  # Seems valid, begin processing
  TRANSACTION {
    # Does such a file currently exist?
    if {[SELECTR [list fileid size] FROM files \
         WHERE owner = $userid AND name = [' $name] \
         FOR UPDATE]} {
      # Yes
      set sizeDelta [expr {[effectiveSize $newsize] - [effectiveSize $size]}]
      log info "Update file $name ($fileid), size $size -> $newsize"
    } else {
      # No, create
      INSERT INTO files (owner,name,size,isPublic) \
      VALUES ($userid, [' $name], $newsize, $isPublic)
      SELECTR fileid FROM files WHERE owner = $userid AND name = [' $name]
      set sizeDelta [effectiveSize $newsize]
      log info "Create file $name ($fileid), size $newsize"
    }

    # Will this break the quota?
    if {$diskUsage + $sizeDelta > $DISK_QUOTA && !$::isAdmin} {
      # Skip the incomming data
      set blackhole [open /dev/null w]
      fcopy stdin $blackhole -size $newsize
      close $blackhole

      # Return failure
      wl [list action-status no {file insuf_space} "Your disk usage quota has been reached"]
      log warn "Disk quota exceeded"
      break ;# Rollback the transaction
    }

    # Open a temporary output file
    set out [open $FILES_DIR/$userid/tmp wb]
    # Read data into the file
    fcopy stdin $out -size $newsize
    # Done with that
    close $out

    # Ensure the size is correct
    # It could be wrong if the stream closed while copying data
    if {$newsize != [file size $FILES_DIR/$userid/tmp]} {
      # Incomplete
      log error "File input truncated ($newsize vs [file size $FILES_DIR/$userid/tmp])"
      file delete $FILES_DIR/$userid/tmp
      break ;# Abort the transaction
    }

    # Write the new time and public status now, to block if something
    # is about to start reading
    UPDATE files \
    SET lastModified = CURRENT_TIMESTAMP, \
        size = $newsize, \
        isPublic = $isPublic \
    WHERE fileid = $fileid
    # Invalidate any ship using this file as backing
    UPDATE ships \
    SET class = NULL, name = NULL \
    WHERE fileid = $fileid

    # Delete the old file and rename the new one to it
    file delete $FILES_DIR/$userid/$fileid
    file rename $FILES_DIR/$userid/tmp $FILES_DIR/$userid/$fileid

    # Final cleanup
    log info "File create/update success"
    set diskUsage [expr {$diskUsage+$sizeDelta}]

    # Indicate success
    wl [list action-status $fileid {general success} "The operation completed successfully"]
  }
}

proc message-top-whois userid {
  assert_integer $userid
  set name {}
  SELECTRA [list friendlyName name] FROM accounts WHERE userid = $userid
  wl [list user-name $name]
}

proc message-top-ships-obsolete {clockself clockother} {
  assert_integer $clockself
  assert_integer $clockother
  set lstr "Get ships obsolete; rel modified: "
  append lstr "[clockToDate $clockself], "
  append lstr "rel posted: [clockToDate $clockother]"
  log info $lstr
  set ret [SELECTALLF shipid, fileid, owner, name \
           FROM allSubscriptions \
           WHERE subscriber = $::userid \
             AND ((owner  = $::userid AND modified > '[clockToDate $clockself]') \
              OR  (owner != $::userid AND posted > '[clockToDate $clockother]'))]
  wl [list ships-obsolete {*}$ret]
}

proc message-top-ships-all {} {
  set ret [SELECTALLF shipid, fileid, owner, name, modified \
           FROM allSubscriptions \
           WHERE subscriber = $::userid]
  set dat ship-list-all
  foreach {shipid fileid owner name modified} $ret {
    lappend dat $shipid $fileid $owner $name [dateToClock $modified]
  }
  wl $dat
}

proc message-top-user-ls {order first lastex} {
  switch -exact -- $order {
    alphabetic { set orderCol listIxAlpha }
    numships   { set orderCol listIxNShips }
    popularity { set orderCol listIxPop }
    rating     { set orderCol listIxRate }
    default { error "Bad order" }
  }
  assert_integer $first
  assert_integer $lastex
  incr lastex -1

  set ret [SELECTALLF userid, friendlyName \
           FROM accounts \
           WHERE $orderCol BETWEEN $first AND $lastex \
           ORDER BY $orderCol]
  wl [list user-list {*}$ret]
}

proc message-top-ship-ls userid {
  assert_integer $userid
  if {$userid == $::userid} {
    set publicCheck {}
  } else {
    set publicCheck [list AND isPublic = 1]
  }
  set ret [SELECTALLF shipid, fileid, class, name \
           FROM ships \
           WHERE owner = $userid \
             AND name IS NOT NULL \
             {*}$publicCheck]
  wl [list ship-list {*}$ret]
}

proc message-top-record-ship-download shipid {
  assert_integer $shipid
  TRANSACTION {
    # Ensure the ship exists. Also get the download count
    set downloads {}
    SELECTR downloads \
    FROM ships \
    WHERE shipid = $shipid \
      AND isPublic = 1 \
    FOR UPDATE
    if {"" == $downloads} break

    # Ensure we haven't recorded this already
    SELECTRA [list COUNT(*) already] FROM shipDownloads \
    WHERE shipid = $shipid AND userid = $::userid
    if {$already} break

    # OK
    incr downloads
    UPDATE ships SET downloads = $downloads WHERE shipid = $shipid
    INSERT INTO shipDownloads (shipid, userid) VALUES ($shipid, $::userid)
    log info "Recorded download of ship $shipid (now $downloads downloads)"
  }
}

proc message-top-rate-ship {shipid positive} {
  assert_integer $shipid
  assert_boolean positive

  # Make sure valid ship
  SELECTRA [list COUNT(*) exists] \
  FROM ships \
  WHERE shipid = $shipid \
    AND isPublic = 1
  if {!$exists} {
    log warn "Rating on non-existent ship $shipid"
    return
  }

  INSERT INTO shipRecommendations (shipid, userid, recommended) \
  VALUES ($shipid, $::userid, $positive) \
  ON DUPLICATE KEY UPDATE recommended = $positive
  log info "Rated"
}

proc message-top-ship-file-ls {} {
  set ret [SELECTALLF fileid, name \
           FROM files \
           WHERE owner = $::userid AND name LIKE '%.ship']
  wl [list ship-file-list {*}$ret]
}

proc message-top-file-delete fileid {
  assert_integer $fileid
  TRANSACTION {
    if {[SELECTR size FROM files \
         WHERE owner = $::userid AND fileid = $fileid]} {
      DELETE FROM files WHERE owner = $::userid AND fileid = $fileid
      file delete $::FILES_DIR/$::userid/$fileid
      incr ::diskUsage -[effectiveSize $size]
    }
  }
  wl [list action-status yes {general success} "The operation completed successfully"]
}

proc message-top-ship-info shipid {
  assert_integer $shipid
  set downloads 0
  set sumratings 0
  set numratings 0
  SELECTR downloads FROM ships WHERE shipid = $shipid
  SELECTRA [list SUM(recommended) sumratings COUNT(recommended) numratings] \
  FROM shipRecommendations WHERE shipid = $shipid
  if {"" == $sumratings} {set sumratings 0}
  wl [list ship-info $downloads $sumratings $numratings]
}

#proc message-top-ai-report {species generation instance score comptime} {
#  assert_integer $species
#  assert_integer $generation
#  assert_integer $instance
#  assert_signed_integer $score
#  assert_integer $comptime
#  INSERT INTO aiReports \
#  (userid, species, generation, instance, score, comptime) \
#  VALUES ($::userid, $species, $generation, $instance, $score, $comptime)
#}
proc message-top-ai-report args {}

proc message-top-ai-report-2 {species generation cortex
                              instance score comptime} {
  assert_integer $species
  assert_integer $generation
  assert_integer $cortex
  assert_integer $instance
  assert_integer $comptime
  assert_float $score
  if {$cortex < 0 || $cortex > 11} return
  INSERT INTO caiReports \
  (submitter, species, generation, cortex, instance, score, comptime) \
  VALUES \
  ($::userid, $species, $generation, $cortex, $instance, $score, $comptime)
}

proc message-job-done {args} {
  disable job-done job-failed
  set jobid $::jobid
  set ::jobid {}
  $::jobCallback $jobid {*}$args
  DELETE FROM jobs WHERE id = $jobid
  log info "Job $jobid completed successfully."
}

proc message-job-failed {why} {
  disable job-done job-failed
  set jobid $::jobid
  set ::jobid {}
  INSERT INTO jobFailures (user, job) VALUES ($::userid, $jobid)
  UPDATE jobs SET failed = failed+1, startedAt = NULL WHERE id = $jobid
  log warn "Job $jobid failed: $why"
}

proc message-make-me-a-slave {} {
  log info "Entering slave mode."
  set ::JOB_CHECK_INTERVAL 0
}

# Update the user index listings
proc message-admin-update-indices {} {
  log info "Begin updating indices"

  # We don't really NEED a transaction here.
  # While the data may become slightly inconsistent (missing
  # indices), it won't be a serious problem, and doing it
  # this way allows the database to continue functioning
  # otherwise.
  UPDATE accounts \
  SET listIxAlpha = NULL, listIxNShips = NULL, \
      listIxPop   = NULL, listIxRate   = NULL

  set idNamePairs [SELECTALLF userid, friendlyName \
                   FROM accounts]

  # For alphabetic, create a list of lowercase friendlyName,
  # userid pairs, sort it, then update each user
  # Number of ships is fairly simple, we must just pad
  # each integer with zeros. Include the name as well
  # so that ties are sorted alphabetically.
  # While we scan the list, we might as well do downloads
  # as well.
  # Sorting rating works similarly to downloads, but we
  # need to do a join to get the ratings
  set lfnuid {}
  set sclfnuid {}
  set dclfnuid {}
  set rlfnuid {}
  foreach {id name} $idNamePairs {
    SELECTRA [list COUNT(*) shipCount SUM(downloads) downCount] \
    FROM ships \
    WHERE owner = $id \
      AND isPublic = 1
    SELECTRA [list SUM(recommended)/COUNT(recommended) rating] \
      FROM ships JOIN shipRecommendations \
        ON ships.shipid = shipRecommendations.shipid \
      WHERE ships.owner = $id \
        AND ships.isPublic = 1
    if {"" == $downCount} { set downCount 0}
    if {"" == $shipCount} { set shipCount 0}

    if {"" == $rating} {
      set rating 00000000
    } else {
      # Make it an integer
      set rating [format %09d [expr {int($rating*100000)}]]
    }

    # Invert integers so lowest comes first
    set rating          [format %09d [expr {999999999-$rating}]]
    set shipCount       [format %09d [expr {999999999-$shipCount}]]
    set downCount       [format %09d [expr {999999999-$downCount}]]

    # Add a space at the end so all names are surrounded in braces
    # for the sorting
    set lfn "[string tolower $name] "
    lappend lfnuid [list $lfn $id]
    lappend sclfnuid [list $shipCount $lfn $id]
    lappend dclfnuid [list $downCount $lfn $id]
    lappend rlfnuid [list $rating $lfn $id]
  }
  set ix 0
  foreach {name id} [concat {*}[lsort $lfnuid]] {
    UPDATE accounts \
    SET listIxAlpha = $ix \
    WHERE userid = $id
    incr ix
  }
  set ix 0
  foreach {shipCount name id} [concat {*}[lsort $sclfnuid]] {
    UPDATE accounts \
    SET listIxNShips = $ix \
    WHERE userid = $id
    incr ix
  }
  set ix 0
  foreach {downCount name id} [concat {*}[lsort $dclfnuid]] {
    UPDATE accounts \
    SET listIxPop = $ix \
    WHERE userid = $id
    incr ix
  }
  set ix 0
  foreach {rating name id} [concat {*}[lsort $rlfnuid]] {
    UPDATE accounts \
    SET listIxRate = $ix \
    WHERE userid = $id
    incr ix
  }

  log info "Done updating indices"
  wl [list action-status yes {general success} \
      "The operation completed successfully"]
}

# Deletes an arbitrary file owned by an arbitrary user
proc message-admin-delete-file {userid fileid} {
  assert_integer $fileid
  assert_integer $userid
  log info "Admin delete $userid/$fileid"
  DELETE FROM files WHERE fileid = $fileid
  file delete $::FILES_DIR/$userid/$fileid
}

proc htmlesc {str} {
  string map [list < "&lt;" > "&gt;" & "&amp;" "\"" "&quot;"] $str
}

# Generates "dynamic" website pages for each user
proc message-admin-generate-user-pages {} {
  log info "Beginning to generate webpages."
  set users [SELECTALLF userid, friendlyName \
             FROM accounts \
             ORDER BY friendlyName]
  file mkdir $::WWW_GEN_DIR/users
  # Generate the index
  log info "index..."
  set out [open $::WWW_GEN_DIR/users/list.shtml w]
  puts -nonewline $out \
"<!--#set var=\"DYN_DOCUMENT_TITLE\" value=\"Users\" -->"
  puts $out "<!--#include virtual=\"/common.shtml\" -->"
  puts $out "<h1>Abendstern Users</h1>"
  foreach {userid friendlyName} $users {
    if {![SELECTRA {COUNT(*) numShips} \
          FROM ships \
          WHERE owner = $userid \
          AND isPublic]} {
      set numShips 0
    }
    if {$numShips == 1} {
      set pluralShips ship
    } else {
      set pluralShips ships
    }
    puts $out "<h2><a href=\"$::WWW_GEN_DIR_REL/users/$userid.shtml\">"
    puts $out "[htmlesc $friendlyName] ($numShips public $pluralShips)"
    puts $out "</a></h2>"

    # Show some of the user's ships
    puts $out "<div class=\"shipthumblist\">"
    foreach {shipid shipname} [SELECTALLF shipid, name \
                               FROM ships \
                               WHERE owner = $userid \
                               AND rendered \
                               AND isPublic \
                               ORDER BY rand() \
                               LIMIT 4] {
      set img $::WWW_PUBFILES_DIR_REL/shipthumbs/$shipid.png
      puts $out "<div class=\"shipthumb\">"
      puts $out "<a href=\"$img\">"
      puts $out "&quot;[htmlesc $shipname]&quot;</a><br />"
      puts $out "<a href=\"$img\">"
      puts $out "<img class=\"shipthumbimg\" src=\"$img\" alt=\"Thumbnail\" />"
      puts $out "</a></div>"
    }
    puts $out "</div>"
  }

  puts $out "<!--#include virtual=\"/commonend.shtml\" -->"

  close $out
  log info "index done."

  # Generate a page for each user
  foreach {userid friendlyName} $users {
    log info "pages for $userid ($friendlyName)..."
    set escapedName [htmlesc $friendlyName]
    set out [open $::WWW_GEN_DIR/users/$userid.shtml w]
    puts -nonewline $out \
"<!--#set var=\"DYN_DOCUMENT_TITLE\" value=\"User: $escapedName\" -->"
    puts $out "<!--#include virtual=\"/common.shtml\" -->"
    puts $out "<h1>$escapedName</h1>"
    set ships [SELECTALLF shipid, name, class \
               FROM ships \
               WHERE owner = $userid \
               AND isPublic \
               AND rendered \
               ORDER BY class, name]
    foreach clazz {C B A} {
      puts $out "<h2>Class $clazz Ships</h2>"
      puts $out "<div class=\"shipthumblist\">"
      foreach {shipid shipname class} $ships {
        if {$class eq $clazz} {
          set img $::WWW_PUBFILES_DIR_REL/shipthumbs/$shipid.png
          puts $out "<div class=\"shipthumb\">"
          puts $out "<a href=\"$img\">"
          puts $out "&quot;[htmlesc $shipname]&quot;</a><br />"
          puts $out "<a href=\"$img\">"
          puts $out "<img class=\"shipthumbimg\" src=\"$img\" alt=\"Thumbnail\" />"
          puts $out "</a></div>"
        }
      }
      puts $out "</div>"

      log info "pages for $userid done"
    }

    puts $out "<!--#include virtual=\"/commonend.shtml\" -->"
    close $out
  }

  log info "done"
  wl [list action-status yes {general success} \
      "The operation completed successfully"]
}

proc job-done-render-ship {jobid fileid} {
  assert_integer $fileid
  # Ensure the file belongs to the user, also get the size
  if {![SELECTR size FROM files \
        WHERE fileid = $fileid AND owner = $::userid]} {
    error "File $filed does not exist or does not belong to $::userid"
  }

  if {![SELECTR job FROM jobs WHERE id = $jobid]} {
    log error "Job $jobid seems to have disappeared!"
    return
  }

  set shipFileId [lindex $job 1]
  if {![SELECTR shipid FROM ships WHERE fileid = $shipFileId]} {
    log warn "The ship $shipd has been deleted since $jobid completed"
    return
  }

  # Ensure the file is a PNG
  set mimeType [exec file -b --mime-type $::FILES_DIR/$::userid/$fileid]
  if {[string trim $mimeType] != "image/png"} {
    error "'Tis a lie! $::userid/$fileid isn't a ship image, it's a $mimeType!"
  }

  # Move it to the ship thumbnails directory
  file rename -force -- $::FILES_DIR/$::userid/$fileid \
      $::PUBFILES_DIR/shipthumbs/$shipid.png
  # Remove the file from the database
  DELETE FROM files WHERE fileid = $fileid
  incr ::diskUsage -[effectiveSize $size]

  # Mark the ship as rendered
  UPDATE ships SET rendered = 1 WHERE shipid = $shipid
}

proc job-done-ship-match {jobid score} {
  if {![string is double -strict $score] ||
      $score < -1.0 || $score > +1.0} {
    error "Invalid ship-match score: $score"
  }

  if {![SELECTR job FROM jobs WHERE id = $jobid]} {
    log error "Job $jobid seems to have disappeared!"
  }

  UPDATE ships \
  SET aiscore = 0.9*aiscore + 0.1*$score \
  WHERE fileid = [lindex $job 1]
}

main
