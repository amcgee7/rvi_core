#!/usr/bin/python

#
# Copyright (C) 2014, Jaguar Land Rover
#
# This program is licensed under the terms and conditions of the
# Mozilla Public License, version 2.0.  The full text of the 
# Mozilla Public License is at https://www.mozilla.org/MPL/2.0/
#
# 
# Simple RVI service caller
#  

import sys
from rvilib import RVI
import threading
import time

def usage():
    print "Return the name of all available services that can be reached"
    print "through an RVI node."
    print
    print "Usage:", sys.argv[0], " RVI-node"
    print
    print "Example: ./callrvi.py http://rvi1.nginfotpdx.net:8801"
    print
    sys.exit(255)


# 
# Check that we have the correct arguments
#
if len(sys.argv) <2:
    usage()

progname = sys.argv[0]
rvi_node = sys.argv[1]


#
# Setup an outbound JSON-RPC connection to the backend RVI node
# Service Edge.
#
rvi = RVI(rvi_node)


print "RVI Node:         ", rvi_node


#
# Send the messge.
#
print rvi.get_available_services()






