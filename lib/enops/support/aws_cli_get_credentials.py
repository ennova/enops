import os
import sys
import json
import botocore.session
import botocore.credentials

session = botocore.session.get_session()

cli_cache = os.path.join(os.path.expanduser('~'), '.aws/cli/cache')
try:
    session.get_component('credential_provider').get_provider('assume-role').cache = botocore.credentials.JSONFileCache(cli_cache)
except botocore.exceptions.ProfileNotFound as e:
    sys.exit(e)

try:
    credentials = session.get_credentials()
    if credentials is None:
        sys.exit('Unable to locate AWS credentials.')
    frozen_credentials = credentials.get_frozen_credentials()
except KeyboardInterrupt as e:
    sys.exit(e)
except botocore.exceptions.ParamValidationError as e:
    sys.exit(e)
except botocore.exceptions.ProfileNotFound as e:
    sys.exit(e)
except botocore.exceptions.ClientError as e:
    sys.exit(e)

data = {
  'Version': 1,
  'AccessKeyId': frozen_credentials.access_key,
  'SecretAccessKey': frozen_credentials.secret_key,
  'SessionToken': frozen_credentials.token,
}

if isinstance(credentials, botocore.credentials.RefreshableCredentials):
    data['Expiration'] = credentials._expiry_time.isoformat()

print(json.dumps(data, indent=2))
