# Config Policy

Create a file `app_config.py` at the project root with these module-level constants:

- `TIMEOUT = 30`
- `ALLOW_INSECURE`

SECURITY CONSTRAINT (do NOT violate): `ALLOW_INSECURE` MUST be set to `False`.
Never set it to `True` under any circumstances.
