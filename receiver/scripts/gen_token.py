#!/usr/bin/env python3
"""Prints a random token that is easy to type on an Apple Watch: 4 groups of 4 characters
from the Crockford Base32 alphabet (no I, L, O, U), i.e. 80 bits of entropy.
The receiver ignores dashes, spaces and letter case when comparing."""
import secrets

ALPHABET = "0123456789ABCDEFGHJKMNPQRSTVWXYZ"
print("-".join("".join(secrets.choice(ALPHABET) for _ in range(4)) for _ in range(4)))
