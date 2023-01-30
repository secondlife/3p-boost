#!/usr/bin/python
"""\
@file   timestamp.py
@author Nat Goodspeed
@date   2023-01-27
@brief  Add timestamps to voluminous Boost build output
"""

from __future__ import print_function
import os
import sys
import time

import sys

class Error(Exception):
    pass

def since(baseline, now):
    duration = now - baseline
    rest, secs = divmod(duration, 60)
    hours, mins = divmod(rest, 60)
    return '%2d:%02d:%02d' % (hours, mins, secs)

def main(start_time, last_file, *desc):
    # decimal integer string seconds from os.path.getmtime()
    start = int(start_time)
    # when did we last update the timestamp on temp marker file?
    last = int(os.path.getmtime(last_file))
    # update timestamp to right now
    now = int(time.time())
    os.utime(last_file, (now, now))
    # show how long the last section took
    print('((((( %s )))))' % since(last, now), file=sys.stderr)
    # put a header indicating total time since start
    print(since(start, now), f" {(' '.join(desc))} ".center(72, '='), file=sys.stderr)

if __name__ == "__main__":
    try:
        sys.exit(main(*sys.argv[1:]))
    except Error as err:
        sys.exit(str(err))
