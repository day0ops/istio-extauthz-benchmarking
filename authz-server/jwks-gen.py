#!/usr/bin/python

"""Python script generates a JWKS custom private key.

Example:
./gen-jwt.py key.pem -jwks <jwks path>
"""
from __future__ import print_function
import argparse
import copy
import time

from jwcrypto import jwt, jwk

from warnings import filterwarnings
filterwarnings("ignore")

def main(args):
    """Generates a signed JSON Web Token from local private key."""
    with open(args.key) as f:
        pem_data = f.read()
    f.closed

    pem_data_encode = pem_data.encode("utf-8")
    key = jwk.JWK.from_pem(pem_data_encode)

    if args.jwks:
        with open(args.jwks, "w+") as fout:
            fout.write("{ \"keys\":[ ")
            fout.write(key.export(private_key=False))
            fout.write("]}")
        fout.close

    return key.key_id

if __name__ == '__main__':
    parser = argparse.ArgumentParser(
        description=__doc__,
        formatter_class=argparse.RawDescriptionHelpFormatter)

    parser.add_argument('key',
        help='The path to the key pem file. The key can be generated with openssl command: `openssl genrsa -out key.pem 2048`')

    parser.add_argument("-jwks", "--jwks",
                        help="Path to the output file for JWKS.")

    print(main(parser.parse_args()))