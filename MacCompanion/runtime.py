"""Packaged companion entry point; preserves the existing CLI and worker."""
import json
import os
from pathlib import Path
import ssl
import sys
import urllib.error
import urllib.request


def main():
    if getattr(sys, "frozen", False):
        os.environ["PATH"] = str(Path(sys._MEIPASS) / "tools") + os.pathsep + "/usr/bin:/bin:/usr/sbin:/sbin"
    if sys.argv[1:2] == ["--worker"]:
        del sys.argv[1]
        from companion_worker import main as worker
        return worker()
    if sys.argv[1:2] == ["--desktop-status"]:
        from companion_security import CompanionConfig
        config = CompanionConfig(sys.argv[2])
        try:
            # Only the configured private host, verified against its own cert.
            opener = urllib.request.build_opener(
                urllib.request.ProxyHandler({}),
                urllib.request.HTTPSHandler(context=ssl.create_default_context(cafile=str(config.cert))))
            with opener.open(config.url + "/v1/health", timeout=2) as response:
                ready = response.status == 200
        except urllib.error.HTTPError as error:
            ready = error.code == 401
            error.close()
        except OSError:
            ready = False
        print(json.dumps({"ready": ready}))
        return
    from companion import main as cli
    return cli()


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except Exception as error:
        print(str(error), file=sys.stderr)
        raise SystemExit(1)
