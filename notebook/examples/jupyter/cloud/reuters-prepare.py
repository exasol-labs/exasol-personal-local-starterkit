# Ad-hoc utility to convert reuters data into bunch of one-line json documents,
# as multi-line is not yet supported.
import json
import pathlib

INPUT_PATH = pathlib.Path("reuters-000.json")
OUTPUT_PREFIX = "reuters-out/reuters1-000"


if __name__ == "__main__":
    data = INPUT_PATH.read_bytes()
    data_dict = json.loads(data)
    print(len(data_dict))
    print(INPUT_PATH.stem)

    for idx, entry in enumerate(data_dict):
        with pathlib.Path(OUTPUT_PREFIX + f"{idx:04d}.json").open("w") as fd:
            fd.write(json.dumps(entry))
