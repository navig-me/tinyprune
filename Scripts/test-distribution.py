#!/usr/bin/env python3
"""Pure release-channel policy regressions; no signing keys or macOS tools required."""
import base64
import os
import unittest
from unittest.mock import patch
import xml.etree.ElementTree as ET

import distribution


class DistributionTests(unittest.TestCase):
    def setUp(self):
        self.environment = patch.dict(os.environ, {
            'RELEASE_TAG': 'v1.2.3', 'SPARKLE_ED25519_PUBLIC_KEY': '',
        })
        self.environment.start()
        self.addCleanup(self.environment.stop)
        # Public-key-shaped fixture bytes only; never used for cryptographic signing.
        self.key = base64.b64encode(bytes(range(32))).decode()
        self.info = {
            'TinyPruneDistribution': 'direct', 'TinyPruneSigning': 'ad-hoc',
            'CFBundleVersion': '42', 'CFBundleShortVersionString': '1.2.3',
            'SUPublicEDKey': self.key, 'TinyPruneUpdatesEnabled': True,
            'SUEnableAutomaticChecks': True, 'SURequireSignedFeed': True,
            'SUVerifyUpdateBeforeExtraction': True, 'SUSignedFeedFailureExpirationInterval': 0,
            'SUAllowsAutomaticUpdates': False, 'SUAutomaticallyUpdate': False,
        }
        self.metadata = {'signing': 'unsigned', 'build': '42'}

    def test_adhoc_and_developer_id_direct_are_eligible(self):
        self.assertEqual(distribution.bundle_configuration(self.info, self.metadata), (self.key, '42'))
        self.info['TinyPruneSigning'] = 'developer-id'
        self.metadata['signing'] = 'signed'
        self.assertEqual(distribution.bundle_configuration(self.info, self.metadata), (self.key, '42'))

    def test_homebrew_is_never_eligible(self):
        self.info['TinyPruneDistribution'] = 'homebrew'
        with self.assertRaises(ValueError):
            distribution.bundle_configuration(self.info, self.metadata)

    def test_missing_embedded_key_skips_only_disabled_bundle(self):
        self.info.pop('SUPublicEDKey')
        self.info['TinyPruneUpdatesEnabled'] = False
        self.info['SUEnableAutomaticChecks'] = False
        self.assertIsNone(distribution.bundle_configuration(self.info, self.metadata))
        self.info['TinyPruneUpdatesEnabled'] = True
        with self.assertRaises(ValueError):
            distribution.bundle_configuration(self.info, self.metadata)

    def test_invalid_or_mismatched_keys_fail(self):
        self.info['SUPublicEDKey'] = 'not-base64'
        with self.assertRaises(ValueError):
            distribution.bundle_configuration(self.info, self.metadata)
        self.info['SUPublicEDKey'] = self.key
        with patch.dict(os.environ, {'SPARKLE_ED25519_PUBLIC_KEY': base64.b64encode(bytes(32)).decode()}):
            with self.assertRaises(ValueError):
                distribution.bundle_configuration(self.info, self.metadata)

    def test_metadata_build_and_verification_policy_must_match(self):
        for key, value in [('CFBundleVersion', '43'), ('CFBundleShortVersionString', '1.2.4'),
                           ('SURequireSignedFeed', False), ('SUVerifyUpdateBeforeExtraction', False),
                           ('SUSignedFeedFailureExpirationInterval', 60), ('SUAllowsAutomaticUpdates', True)]:
            with self.subTest(key=key):
                info = dict(self.info, **{key: value})
                with self.assertRaises(ValueError):
                    distribution.bundle_configuration(info, self.metadata)

    def feed(self, current='42', previous='41', enclosure_version=None):
        root = ET.Element('rss')
        channel = ET.SubElement(root, 'channel')
        for url, build in [('previous', previous), ('released', current)]:
            item = ET.SubElement(channel, 'item')
            ET.SubElement(item, '{' + distribution.NS + '}version').text = build
            enclosure = ET.SubElement(item, 'enclosure', url=url)
            if url == 'released' and enclosure_version is not None:
                enclosure.set('{' + distribution.NS + '}version', enclosure_version)
        return root

    def test_exact_build_and_monotonic_prior_entries(self):
        distribution.validate_feed_builds(self.feed(), 'released', '42')
        for current, previous in [('43', '41'), ('42', '42'), ('42', '43'), ('42', 'bad')]:
            with self.subTest(current=current, previous=previous):
                with self.assertRaises(ValueError):
                    distribution.validate_feed_builds(self.feed(current, previous), 'released', '42')
        with self.assertRaises(ValueError):
            distribution.validate_feed_builds(self.feed(enclosure_version='43'), 'released', '42')

    def test_legacy_enclosure_build_is_supported(self):
        tree = self.feed()
        for item in tree.findall('./channel/item'):
            version = item.find('{' + distribution.NS + '}version')
            item.find('enclosure').set('{' + distribution.NS + '}version', version.text)
            item.remove(version)
        distribution.validate_feed_builds(tree, 'released', '42')

    def test_release_build_requires_positive_decimal_counter(self):
        for value in ['0', '01', '-1', '1.2.3', None, 42]:
            with self.subTest(value=value):
                with self.assertRaises(ValueError):
                    distribution.release_build(value)


if __name__ == '__main__':
    unittest.main()
