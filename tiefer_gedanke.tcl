# File to use for headless.tcl in the Tiefer Gedanke.
# It requires a file named credentials to supply the username and password, but
# does not need to run on the Abendstern server.
#
# It logs to stderr instead of using log, so:
# (1) It won't work on Windows
# (2) You can safely redirect stdout to /dev/null
#
# Note that the program never terminates; if the connection is lost, it will
# try again later.

source credentials

proc elog {msg} {
  puts stderr \
      "[clock format [clock seconds] -format {%Y.%m.%d %H:%M:%S}]: $msg"
}

proc sleep {ms} {
  set ::sleepDone {}
  unset ::sleepDone
  after $ms {set ::sleepDone done}
  vwait ::sleepDone
}

while {true} {
  ::abnet::openConnection
  vwait ::abnet::busy
  if {!$::abnet::isReady} {
    elog "Unable to connect to server: $::abnet::resultMessage"
    elog "Retrying in 30 minutes..."
    sleep [expr {30*60*1000}]
    continue
  }

  ::abnet::login $USERNAME $PASSWORD
  vwait ::abnet::busy
  if {!$::abnet::isConnected || !$::abnet::success} {
    elog "Unable to log in: $::abnet::resultMessage"
    error "Invalid credentials"
  }

  ::abnet::slaveMode

  elog "Online."
  while {$::abnet::isConnected} {
    # Poll isConnected every 5 minutes
    sleep 300000
    elog "Connection status: $::abnet::isConnected"
  }

  elog "Connection to the Abendstern Network lost!"
  elog "Reconnecting in 5 minutes..."
  sleep 300000
}
