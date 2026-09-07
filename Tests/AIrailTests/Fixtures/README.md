# Recorded endpoint fixtures

Redacted copies of what each usage endpoint actually sends, one file per
endpoint, recorded from the sign-ins on a real Mac:

    TEST_RUNNER_AIRAIL_LIVE=1 TEST_RUNNER_AIRAIL_RECORD_FIXTURES=1 \
      xcodebuild -scheme AIrail test -only-testing:AIrailTests/LiveProviderTests

Strings are kept only under keys that carry no personal data (plan names,
model ids, dates); every other string is replaced with "…". Numbers, booleans
and the structure stay. Once a fixture exists, every live run checks that the
endpoint still sends every key path the fixture has, so a moved endpoint
fails here before it fails on someone's rail.
