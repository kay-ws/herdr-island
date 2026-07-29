# statusLine の stdin payload から Agents パネル用の値を取り出す。
# 出力: "<ctx>\t<limits>" の TSV 1 行。取れない側は空文字。

def pct:
  (.context_window.current_usage) as $u
  | (.context_window.context_window_size) as $size
  | if ($u == null) or ($size == null) or ($size == 0) then null
    else
      ( (($u.input_tokens // 0)
         + ($u.cache_creation_input_tokens // 0)
         + ($u.cache_read_input_tokens // 0)) * 100 / $size | floor )
    end;

# rate_limits はセッション最初の API 応答後にしか出現しない。
# 無ければ null を返し、呼び出し側は送信を見送る（クリアはしない）。
def limits:
  [ (.rate_limits.five_hour.used_percentage  | if . == null then empty else "5h \(round)%" end),
    (.rate_limits.seven_day.used_percentage  | if . == null then empty else "7d \(round)%" end) ]
  | if length == 0 then null else join(" | ") end;

[ (pct    | if . == null then "" else "\(.)%" end),
  (limits | if . == null then "" else . end) ]
| @tsv
