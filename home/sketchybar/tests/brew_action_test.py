"""The terminal branch must signal completion after brew returns, even on error."""
from pathlib import Path
import os
import signal
import subprocess
import tempfile
import time
import unittest

SCRIPT = Path(__file__).parents[1] / 'sketchybar/helpers/brew_action.sh'


class BrewActionTests(unittest.TestCase):
    def test_refresh_follows_command_completion(self):
        with tempfile.TemporaryDirectory() as tmp:
            tmp = Path(tmp)
            # A real native process gives pkill the same argv shape as brew_check.
            source = tmp / 'provider.c'
            source.write_text('''#include <signal.h>
#include <stdio.h>
#include <unistd.h>
int main(int argc, char **argv) {
 sigset_t set; sigemptyset(&set); sigaddset(&set,SIGUSR1);
 sigprocmask(SIG_BLOCK,&set,0);
 FILE *f=fopen(argv[2],"w"); fclose(f);
 int received; sigwait(&set,&received);
 return access(argv[3],F_OK)==0 ? 0 : 9;
}''')
            provider = tmp / 'brew_check'
            subprocess.run([os.environ.get('CC', 'clang'), str(source), '-o', str(provider)], check=True)
            ready, done = tmp / 'ready', tmp / 'done'
            brew = tmp / 'brew'
            brew.write_text('#!/bin/sh\nsleep 0.2\nprintf done > "' + str(done) + '"\nexit 7\n')
            brew.chmod(0o700)
            process = subprocess.Popen([str(provider), 'brew_update', str(ready), str(done)])
            try:
                deadline = time.monotonic() + 3
                while not ready.exists() and time.monotonic() < deadline:
                    time.sleep(.01)
                self.assertTrue(ready.exists())
                result = subprocess.run(['/bin/bash', str(SCRIPT), '--run', str(brew), str(provider), 'upgrade'],
                                        stdin=subprocess.DEVNULL, capture_output=True, timeout=5)
                self.assertEqual(result.returncode, 7, 'preserve brew exit status')
                self.assertEqual(process.wait(timeout=3), 0, 'refresh must follow completion')
            finally:
                if process.poll() is None:
                    process.kill()
                    process.wait()


if __name__ == '__main__':
    unittest.main()
