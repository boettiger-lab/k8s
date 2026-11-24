# merge-store.py SRC DST — copy every key of LevelDB SRC into DST (k8s#52).
# Refuses, writing nothing, if any key already exists in DST with a different value.
# Both must be closed copies (service scaled to 0). Needs plyvel:
#   uv run --no-project --with plyvel python merge-store.py SRC DST
import sys, plyvel
src = plyvel.DB(sys.argv[1], create_if_missing=False, paranoid_checks=True)
dst = plyvel.DB(sys.argv[2], create_if_missing=False, paranoid_checks=True)
new = same = 0
for k, v in src.iterator():
    cur = dst.get(k)
    if cur is None: new += 1
    elif cur == v: same += 1
    else: sys.exit(f"CONFLICT on key {k[:32].hex()} - aborting, nothing written")
wb = dst.write_batch(sync=True)
for k, v in src.iterator():
    if dst.get(k) is None: wb.put(k, v)
wb.write()
print(f"merged: {new} new keys, {same} identical, dst now {sum(1 for _ in dst.iterator())} keys")
src.close(); dst.close()
