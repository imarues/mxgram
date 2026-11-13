import os
import argparse

# Mọi path suy ra từ vị trí script -> chạy được trên máy bất kỳ, không phụ thuộc CWD
SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
DEFAULT_BUNDLE = os.path.join(SCRIPT_DIR, "Kira.bundle")
DEFAULT_OUTPUT = os.path.join(SCRIPT_DIR, "Sources", "tgapi", "UI", "EmbeddedLangs.h")

parser = argparse.ArgumentParser(
    description="Sinh EmbeddedLangs.h từ các Localizable.strings trong Kira.bundle"
)
parser.add_argument("--bundle", default=DEFAULT_BUNDLE, help=f"Đường dẫn Kira.bundle (mặc định: {DEFAULT_BUNDLE})")
parser.add_argument("--output", default=DEFAULT_OUTPUT, help=f"File header xuất ra (mặc định: {DEFAULT_OUTPUT})")
args = parser.parse_args()

bundle_path = args.bundle
output_path = args.output

if not os.path.isdir(bundle_path):
    raise SystemExit(f"Không tìm thấy bundle: {bundle_path}")

# Sắp xếp để output ổn định giữa các lần chạy / các máy
lprojs = sorted(d for d in os.listdir(bundle_path) if d.endswith(".lproj"))

# static inline: header được import từ nhiều .m, non-static sẽ gây duplicate symbol khi link
out = "#import <Foundation/Foundation.h>\n\n"
out += "static inline NSDictionary *GetAllTranslations(NSString *code) {\n"

for lproj in lprojs:
    code = lproj.replace(".lproj", "")
    strings_path = os.path.join(bundle_path, lproj, "Localizable.strings")
    if not os.path.exists(strings_path): continue

    out += f'    if ([code isEqualToString:@"{code}"]) {{\n'
    out += f'        return @{{\n'

    with open(strings_path, 'r', encoding='utf-8') as f:
        for line in f:
            line = line.strip()
            if not line or line.startswith("/*") or line.startswith("//"): continue
            if "=" in line:
                key, val = line.split("=", 1)
                key = key.strip().strip('"')
                val = val.strip().strip('";')
                # Escape quotes
                val = val.replace('"', '\\"')
                out += f'            @"{key}": @"{val}",\n'

    out += f'        }};\n'
    out += f'    }}\n'

out += "    return nil;\n}\n"

os.makedirs(os.path.dirname(output_path), exist_ok=True)
with open(output_path, "w", encoding='utf-8') as f:
    f.write(out)

print(f"Đã ghi {output_path} ({len(lprojs)} ngôn ngữ)")
