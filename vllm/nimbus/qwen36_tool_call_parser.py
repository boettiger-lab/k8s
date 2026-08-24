# SPDX-License-Identifier: Apache-2.0
# Patch for nimbus/qwen-tool-call-parser-bug — see qwen-deployment-notes.md.
#
# Root cause (traced against NGC vLLM 0.21.0+2325b6f0.nvinternal.26.5.post1,
# vllm/tool_parsers/qwen3xml_tool_parser.py): when the model emits multiple
# <function=...> blocks inside a single <tool_call> element, the upstream
# StreamingXMLToolCallParser._end_element("function") handler closes the
# JSON with '}' / '{}' but never resets current_function_name/parameters,
# and tool_call_index is only bumped on <tool_call>, not on each sibling
# <function>. So the second function's delta stream reuses the first
# function's leftover parameters dict and OpenAI tool_calls[] slot,
# producing malformed/duplicated JSON (e.g. extra '}', concatenated JSON
# objects -> json.JSONDecodeError: Extra data downstream). Matches
# upstream vLLM issue #43713 (open, unmerged patch as of 2026-07-04):
# https://github.com/vllm-project/vllm/issues/43713
#
# This subclasses rather than monkeypatches so the fix is additive and easy
# to drop once #43713 lands upstream. NOT YET DEPLOYED on nimbus — this is
# a draft mounted the same way Nemotron mounts super_v3_reasoning_parser.py
# (see deploy-nemotron.yaml), registered under a distinct parser name
# (qwen3_xml_patched) so it's opt-in, not a silent override of the stock
# qwen3_xml parser.

from vllm.entrypoints.chat_utils import make_tool_call_id
from vllm.tool_parsers.abstract_tool_parser import ToolParserManager
from vllm.tool_parsers.qwen3xml_tool_parser import (
    Qwen3XMLToolParser,
    StreamingXMLToolCallParser,
)


class PatchedStreamingXMLToolCallParser(StreamingXMLToolCallParser):
    def _end_element(self, name: str):
        super()._end_element(name)
        if name.startswith("function") or name == "function":
            # Reset per-function state and open a fresh tool_call slot so a
            # sibling <function> in the same <tool_call> can't inherit stale
            # parameters or collide on the same OpenAI tool_calls[] index.
            self.current_function_name = None
            self.parameters = {}
            self.current_call_id = make_tool_call_id()
            self.tool_call_index += 1


@ToolParserManager.register_module("qwen3_xml_patched")
class PatchedQwen3XMLToolParser(Qwen3XMLToolParser):
    def __init__(self, tokenizer, tools=None):
        super().__init__(tokenizer, tools)
        self.parser = PatchedStreamingXMLToolCallParser()
