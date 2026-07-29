#!/bin/bash
# 偽 herdr を PATH に仕込み、呼び出し引数を 2 つの形式で記録する。
#
#   $CAPTURE      … 引数を空白で連結した 1 行。順序とペアリングの確認用。
#                   "--token reason=Bash: ls -la" のような並びをそのまま見られる
#   $CAPTURE_ARGS … 1 引数 1 行。word splitting の検出用。
#
# 2 形式に分けている理由: "$*" だけだとクォート漏れを検出できない。
# 例えば --token limits=$limits のようにクォートを落としても、シェルが
# 分割した語を "$*" が同じ空白で再結合してしまうため、連結形は変わらない。
# 1 引数 1 行なら分割された語が別々の行になるので、完全一致行が消えて落ちる。

setup_fake_herdr() {
  FAKE_DIR="$(mktemp -d)"
  CAPTURE="$FAKE_DIR/captured"
  CAPTURE_ARGS="$FAKE_DIR/args"
  cat > "$FAKE_DIR/herdr" <<'FAKE'
#!/bin/bash
printf '%s\n' "$*"  >> "$CAPTURE"
printf '%s\n' "$@"  >> "$CAPTURE_ARGS"
exit 0
FAKE
  chmod +x "$FAKE_DIR/herdr"
  export CAPTURE CAPTURE_ARGS
  export PATH="$FAKE_DIR:$PATH"
}

teardown_fake_herdr() { rm -rf "$FAKE_DIR"; }

reset_capture() { : > "$CAPTURE"; : > "$CAPTURE_ARGS"; }

# has_arg <値> : その値が単独の 1 引数として渡ったか（完全一致行があるか）
has_arg() { grep -Fxq -- "$1" "$CAPTURE_ARGS" && echo yes || echo no; }
