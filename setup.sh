#!/bin/bash
set -e

echo "🔥 TalkPulse Widget Setup"
echo ""

# Check XcodeGen
if ! command -v xcodegen &> /dev/null; then
    echo "📦 XcodeGen not found. Installing..."
    if command -v brew &> /dev/null; then
        brew install xcodegen
    else
        echo "⚠️ Homebrew not found. Please install XcodeGen manually:"
        echo "   brew install xcodegen"
        echo "   or download from https://github.com/yonaskolb/XcodeGen/releases"
        exit 1
    fi
fi

cd "$(dirname "$0")"

DEFAULT_PREFIX="com.example"
BUNDLE_ID_PREFIX="${BUNDLE_ID_PREFIX:-$DEFAULT_PREFIX}"
APP_BUNDLE_ID="${APP_BUNDLE_ID:-${BUNDLE_ID_PREFIX}.talkpulse}"
WIDGET_BUNDLE_ID="${WIDGET_BUNDLE_ID:-${APP_BUNDLE_ID}.widget}"
APP_GROUP_ID="${APP_GROUP_ID:-group.${APP_BUNDLE_ID}}"

echo "🔐 Bundle IDs:"
echo "   App:    $APP_BUNDLE_ID"
echo "   Widget: $WIDGET_BUNDLE_ID"
echo "   Group:  $APP_GROUP_ID"
if [ "$BUNDLE_ID_PREFIX" = "$DEFAULT_PREFIX" ]; then
    echo "   Note: com.example is a placeholder. Use BUNDLE_ID_PREFIX=com.yourname for your own Apple signing team."
fi
echo ""

export BUNDLE_ID_PREFIX APP_BUNDLE_ID WIDGET_BUNDLE_ID APP_GROUP_ID

python3 << 'PYEOF'
import os
import re

path = "project.yml"
with open(path, "r") as f:
    content = f.read()

bundle_id_prefix = os.environ["BUNDLE_ID_PREFIX"]
app_bundle_id = os.environ["APP_BUNDLE_ID"]
widget_bundle_id = os.environ["WIDGET_BUNDLE_ID"]
app_group_id = os.environ["APP_GROUP_ID"]

content = re.sub(r"bundleIdPrefix: .*", f"bundleIdPrefix: {bundle_id_prefix}", content)

lines = content.splitlines()
current_target = None
updated = {"app": False, "widget": False, "app_group": 0}

for index, line in enumerate(lines):
    if re.match(r"^  TalkPulse:$", line):
        current_target = "app"
    elif re.match(r"^  TalkPulseWidgetExtension:$", line):
        current_target = "widget"
    elif re.match(r"^  [A-Za-z0-9_]+:$", line):
        current_target = None

    stripped = line.strip()
    indent = line[:len(line) - len(line.lstrip())]

    if stripped.startswith("PRODUCT_BUNDLE_IDENTIFIER:"):
        if current_target == "app":
            lines[index] = f"{indent}PRODUCT_BUNDLE_IDENTIFIER: {app_bundle_id}"
            updated["app"] = True
        elif current_target == "widget":
            lines[index] = f"{indent}PRODUCT_BUNDLE_IDENTIFIER: {widget_bundle_id}"
            updated["widget"] = True
    elif stripped.startswith("APP_GROUP_IDENTIFIER:"):
        lines[index] = f"{indent}APP_GROUP_IDENTIFIER: {app_group_id}"
        updated["app_group"] += 1

missing = [name for name in ("app", "widget") if not updated[name]]
if missing or updated["app_group"] == 0:
    raise SystemExit(f"Could not update project.yml identifiers: {updated}")

with open(path, "w") as f:
    f.write("\n".join(lines) + "\n")
PYEOF

echo "🛠  Generating Xcode project..."
xcodegen generate

PBXPROJ="TalkPulse.xcodeproj/project.pbxproj"
if [ -f "$PBXPROJ" ]; then
    echo "🔧 Patching .pbxproj..."

    # 1. Fix Widget Extension product type: bundle -> extensionkit-extension
    sed -i '' 's/productType = "com.apple.product-type.bundle";/productType = "com.apple.product-type.extensionkit-extension";/g' "$PBXPROJ"

    # 2. Fix explicitFileType so Xcode treats it as an .appex, not .bundle
    sed -i '' 's/explicitFileType = wrapper.cfbundle;/explicitFileType = wrapper.extensionkit-extension;/g' "$PBXPROJ"

    # 3. Change output path from .bundle to .appex
    sed -i '' 's/path = TalkPulseWidgetExtension.bundle;/path = TalkPulseWidgetExtension.appex;/g' "$PBXPROJ"
    sed -i '' 's/\/\* TalkPulseWidgetExtension.bundle \*\//\/\* TalkPulseWidgetExtension.appex \*\//g' "$PBXPROJ"

    # 4. Move Widget Extension from Resources -> Embed PlugIns
    python3 << 'PYEOF'
import uuid

path = 'TalkPulse.xcodeproj/project.pbxproj'
with open(path, 'r') as f:
    content = f.read()

build_file_id = 'C51602085F238C883F58731E'
file_ref_id = 'B44264787ACC908F4C3A745F'
target_id = '83AD88566E1AD77F5DA9B6C7'

new_build_file_id = uuid.uuid4().hex.upper()[:24]
copy_phase_id = uuid.uuid4().hex.upper()[:24]

# Remove from Resources phase
content = content.replace(
    f'\t\t\t\t{build_file_id} /* TalkPulseWidgetExtension.bundle in Resources */,' ,
    ''
)

# Add new PBXBuildFile for Embed PlugIns
new_build_file = f'\t\t{new_build_file_id} /* TalkPulseWidgetExtension.appex in Embed PlugIns */ = {{isa = PBXBuildFile; fileRef = {file_ref_id}; settings = {{ATTRIBUTES = (CodeSignOnCopy, RemoveHeadersOnCopy, ); }}; }};\n'
content = content.replace('/* End PBXBuildFile section */', new_build_file + '/* End PBXBuildFile section */')

# Add PBXCopyFilesBuildPhase
new_copy_phase = f'''/* Begin PBXCopyFilesBuildPhase section */
\t\t{copy_phase_id} /* Embed PlugIns */ = {{
\t\t\tisa = PBXCopyFilesBuildPhase;
\t\t\tbuildActionMask = 2147483647;
\t\t\tdstPath = "";
\t\t\tdstSubfolderSpec = 13;
\t\t\tfiles = (
\t\t\t\t{new_build_file_id} /* TalkPulseWidgetExtension.appex in Embed PlugIns */,
\t\t\t);
\t\t\tname = "Embed PlugIns";
\t\t\trunOnlyForDeploymentPostprocessing = 0;
\t\t}};
/* End PBXCopyFilesBuildPhase section */
'''
content = content.replace(
    '/* Begin PBXContainerItemProxy section */',
    new_copy_phase + '\n/* Begin PBXContainerItemProxy section */'
)

# Add to TalkPulse target buildPhases
old_phases = f'''\t\t{target_id} /* TalkPulse */ = {{
\t\t\tisa = PBXNativeTarget;
\t\t\tbuildConfigurationList = 5081D29F887A05ABED7DA1ED /* Build configuration list for PBXNativeTarget "TalkPulse" */;
\t\t\tbuildPhases = (
\t\t\t\tBB8B134508D0C3DA95BD410D /* Sources */,
\t\t\t\t50C794CD9FA674CA3F802760 /* Resources */,'''
new_phases = f'''\t\t{target_id} /* TalkPulse */ = {{
\t\t\tisa = PBXNativeTarget;
\t\t\tbuildConfigurationList = 5081D29F887A05ABED7DA1ED /* Build configuration list for PBXNativeTarget "TalkPulse" */;
\t\t\tbuildPhases = (
\t\t\t\tBB8B134508D0C3DA95BD410D /* Sources */,
\t\t\t\t50C794CD9FA674CA3F802760 /* Resources */,
\t\t\t\t{copy_phase_id} /* Embed PlugIns */,'''
content = content.replace(old_phases, new_phases)

with open(path, 'w') as f:
    f.write(content)
PYEOF

    echo "✅ Patched .pbxproj"
fi

echo ""
echo "✅ Project generated: TalkPulse.xcodeproj"
echo ""
echo "🎯 Next steps:"
if [ "${OPEN_XCODE:-1}" != "0" ]; then
    echo "   1. Xcode will open automatically"
else
    echo "   1. Open TalkPulse.xcodeproj in Xcode"
fi
echo "   2. Build (⌘B) and Run (⌘R) the host app"
echo "   3. Desktop right-click → Edit Widgets → find TalkPulse → drag to desktop"
echo ""

if [ "${OPEN_XCODE:-1}" != "0" ]; then
    open TalkPulse.xcodeproj
fi
