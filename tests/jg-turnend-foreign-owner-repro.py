#!/usr/bin/env python3
"""Executable regression for the foreign session-lock owner turn-end loop.

This is adapted from Appendix A of the downstream reproduction report. It
runs the shipped lock, Claude auto-arm, and turn-end guard scripts against
isolated synthetic primary homes and harness-shaped processes.
"""
import json
import os
import pathlib
import shutil
import signal
import subprocess
import tempfile
import time