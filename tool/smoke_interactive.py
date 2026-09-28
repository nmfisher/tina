#!/usr/bin/env python3
"""Compatibility launcher for the engine2 packaged terminal smoke suite."""
import sys
from smoke_engine2 import main

if __name__ == '__main__':
    sys.argv[1:] = ['--binary', *sys.argv[1:]]
    main()
