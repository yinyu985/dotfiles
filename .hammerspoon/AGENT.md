# Agent 约束

## 日志格式

所有 Lua 脚本的日志输出必须通过统一的 logger，禁止直接调用 `print()`（init.lua 中的重载分隔线除外）。

统一格式（与 Hammerspoon 框架日志风格一致，时间戳由 Console 自动添加，脚本只输出 `--` 开头的内容）：

```
-- [module] LEVEL message
```

- `--`: 固定前缀，与框架日志对齐（Console 会自动在前面加时间戳）
- module: 模块名（如 `procmon`、`remote_ocr`、`ocr`）
- LEVEL: `INFO` / `WARN` / `ERROR`，或事件名大写截断至 5 字符（如 `CURL`、`IMAGE`）
- message: 单行，key=value 风格记录结构化数据

示例（Console 中实际显示）：

```
2026-07-22 10:08:31: -- -------------------- RELOAD --------------------
2026-07-22 10:08:31: -- [procmon] INFO  procmon started
2026-07-22 10:08:32: -- [remote_ocr] CURL  done exit=0 http=200 key=1/2 retry=0/1 ms=1234.5
```

## 规则

1. 每个脚本内嵌 logger，保证单文件即可独立运行，方便分发。
2. 禁止在模块中裸调 `print()`、`hs.console.printStyledtext()` 等。
3. 日志消息使用英文，key=value 对之间用空格分隔。
4. 不要在日志中输出完整 base64、完整请求体等大块数据，只记录字节数或截断摘要。
5. 单行日志不超过 100 字符（不含时间戳前缀）。超出时：去掉冗余/可推算的字段，或拆成多行。
6. 不要打装饰符号（如 `== xxx ==`），直接输出文字。
7. 不要重复打印已有信息（如 token 数已在 usage 行出现，time 行不再重复）。
8. 同一信息只在一处打印（如 url_bytes 已在 IMAGE 行出现，REQ 行不再重复）。endpoint 等关键目标地址需要在请求发起时打印。
