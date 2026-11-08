import base64
import json
import sys
import time

samples = 0
print(json.dumps(dict(type='ready')), flush=True)
for line in sys.stdin:
    value = json.loads(line)
    final = value.get('finish') is True
    if not final:
        samples += len(base64.b64decode(value['audio'])) // 2
    print(json.dumps(dict(type='caption', segments=[dict(id='0', start=0, end=samples / 16000, text='backpressure probe', final=final)])), flush=True)
    if final:
        print(json.dumps(dict(type='finished')), flush=True)
        break
    time.sleep(0.2)
