import {
  createContext,
  useCallback,
  useContext,
  useEffect,
  useMemo,
  useState,
  type ReactNode,
} from "react";

import type { NodeSpec, ParamOption, PortSpec } from "./types";

export type Locale = "zh-CN" | "en";

export type LibraryGroupId =
  | "input-media"
  | "model-protocol"
  | "prompt-context"
  | "reasoning"
  | "tools-mcp"
  | "skills"
  | "logic-control"
  | "data-processing"
  | "output"
  | "my-composite";

interface GroupMeta {
  id: LibraryGroupId;
  zh: string;
  en: string;
  icon: string;
}

export const LIBRARY_GROUPS: GroupMeta[] = [
  { id: "input-media", zh: "输入与媒体", en: "Input & Media", icon: "◧" },
  { id: "model-protocol", zh: "模型与协议", en: "Models & Protocols", icon: "◈" },
  { id: "prompt-context", zh: "提示词与上下文", en: "Prompt & Context", icon: "¶" },
  { id: "reasoning", zh: "思考与推理", en: "Reasoning", icon: "◇" },
  { id: "tools-mcp", zh: "工具与 MCP", en: "Tools & MCP", icon: "⚙" },
  { id: "skills", zh: "Skills", en: "Skills", icon: "✦" },
  { id: "logic-control", zh: "逻辑与控制", en: "Logic & Control", icon: "⑂" },
  { id: "data-processing", zh: "数据处理", en: "Data Processing", icon: "≋" },
  { id: "output", zh: "输出", en: "Output", icon: "▤" },
  { id: "my-composite", zh: "我的组合", en: "My Composites", icon: "⬚" },
];

const GROUP_BY_KIND: Record<string, LibraryGroupId> = {
  "core.provider": "model-protocol",
  "core.provider.openai_chat": "model-protocol",
  "core.provider.openai_responses": "model-protocol",
  "core.provider.anthropic_messages": "model-protocol",
  "core.model": "model-protocol",
  "core.prompt": "prompt-context",
  "core.context": "prompt-context",
  "core.reasoning": "reasoning",
  "core.tool_set": "tools-mcp",
  "core.tool_dispatch": "tools-mcp",
  "core.mcp_server": "tools-mcp",
  "core.skill": "skills",
  "core.condition": "logic-control",
  "core.loop_gate": "logic-control",
  "core.approval": "logic-control",
  "core.counter": "logic-control",
  "core.text_input": "input-media",
  "core.number_input": "input-media",
  "core.boolean_input": "input-media",
  "core.input.image": "input-media",
  "core.input.audio": "input-media",
  "core.input.video": "input-media",
  "core.input.document": "input-media",
  "core.text_uppercase": "data-processing",
  "core.text_concat": "data-processing",
  "core.number_add": "data-processing",
  "core.log": "output",
  "core.composite": "my-composite",
};

const CATEGORY_FALLBACK: Record<string, LibraryGroupId> = {
  Input: "input-media",
  Media: "input-media",
  Agent: "model-protocol",
  Tools: "tools-mcp",
  Text: "data-processing",
  Number: "data-processing",
  Logic: "logic-control",
  Control: "logic-control",
  Output: "output",
  Composite: "my-composite",
};

const NODE_TEXT: Record<string, { title: string; description: string }> = {
  "core.text_input": { title: "文本输入", description: "输出一段固定文本" },
  "core.number_input": { title: "数字输入", description: "输出一个固定数值" },
  "core.boolean_input": { title: "布尔输入", description: "输出真或假" },
  "core.text_uppercase": { title: "转大写", description: "将输入文本转换为大写" },
  "core.text_concat": { title: "文本拼接", description: "用分隔符连接两段文本" },
  "core.number_add": { title: "加法", description: "计算两个数字之和" },
  "core.log": { title: "日志输出", description: "把输入值写入运行日志" },
  "core.approval": { title: "审批门", description: "暂停并等待人工批准" },
  "core.condition": { title: "条件分支", description: "按布尔条件选择执行路径" },
  "core.loop_gate": { title: "循环门", description: "控制循环继续或退出" },
  "core.counter": { title: "计数器", description: "按步长累加并输出当前值" },
  "core.input.image": { title: "图片输入", description: "读取本地图片并生成多模态内容" },
  "core.input.audio": { title: "音频输入", description: "读取音频或提供明确转写文本" },
  "core.input.video": { title: "视频输入", description: "按时间抽帧或使用原生视频" },
  "core.input.document": { title: "文档输入", description: "从 PDF、DOCX、TXT、MD 提取文本" },
  "core.provider": { title: "服务提供方", description: "声明 OpenAI Chat 兼容服务，凭据只存引用" },
  "core.provider.openai_chat": { title: "OpenAI Chat", description: "OpenAI Chat Completions 协议" },
  "core.provider.openai_responses": { title: "OpenAI Responses", description: "OpenAI Responses 协议与响应状态" },
  "core.provider.anthropic_messages": { title: "Anthropic Messages", description: "Anthropic Messages 协议与内容块" },
  "core.model": { title: "模型调用", description: "调用统一模型运行时并输出文本与工具调用" },
  "core.reasoning": { title: "思考等级", description: "为模型选择协议相关的推理强度" },
  "core.prompt": { title: "提示词", description: "从模板构建系统与用户消息" },
  "core.context": { title: "上下文管理", description: "维护每轮对话历史与裁剪策略" },
  "core.tool_set": { title: "工具集", description: "汇总内置、MCP 与技能工具" },
  "core.tool_dispatch": { title: "工具调度", description: "执行模型请求的工具并回填结果" },
  "core.mcp_server": { title: "MCP 服务", description: "连接 stdio 或 Streamable HTTP MCP 服务" },
  "core.skill": { title: "技能", description: "把本地技能说明注入提示词" },
  "core.composite": { title: "组合", description: "把多个节点封装为可展开子图" },
};

const PORT_TEXT: Record<string, string> = {
  text: "文本",
  number: "数字",
  value: "值",
  boolean: "布尔",
  condition: "条件",
  payload: "负载",
  json: "JSON",
  run: "运行",
  start: "开始",
  next: "继续",
  stop: "停止",
  continue: "继续",
  exit: "退出",
  done: "完成",
  true: "真",
  false: "假",
  pass: "通过",
  reject: "拒绝",
  a: "输入 A",
  b: "输入 B",
  prompt: "提示词",
  system: "系统提示词",
  user: "用户消息",
  messages: "消息列表",
  context: "上下文",
  handle: "句柄",
  assistant: "助手消息",
  toolResults: "工具结果",
  toolset: "工具集",
  tools: "工具",
  toolCalls: "工具调用",
  hasToolCalls: "含工具调用",
  usage: "用量",
  provider: "服务提供方",
  config: "配置",
  model: "模型",
  reasoning: "思考配置",
  reasoningSummary: "思考摘要",
  capabilities: "能力",
  assets: "媒体资源",
  parts: "内容片段",
  images: "图片",
  frames: "帧",
  count: "数量",
  summary: "摘要",
  pages: "页数",
  level: "等级",
  mcp: "MCP 工具",
  resources: "资源",
  skill: "技能",
  skillId: "技能 ID",
  namespace: "命名空间",
  response: "响应",
};

const PARAM_TEXT: Record<string, string> = {
  text: "文本",
  value: "值",
  a: "输入 A",
  b: "输入 B",
  separator: "分隔符",
  prefix: "前缀",
  start: "起始值",
  step: "步长",
  threshold: "阈值",
  maxIterations: "最大迭代次数",
  timeoutMs: "超时（毫秒）",
  message: "提示信息",
  model: "模型",
  temperature: "温度",
  maxTokens: "最大输出 Token",
  reasoningEffort: "思考等级（旧版）",
  stream: "流式输出",
  maxCalls: "最大模型调用次数",
  maxTotalTokens: "总 Token 上限",
  capabilities: "能力覆盖（JSON）",
  providerId: "提供方 ID",
  baseUrl: "基础地址",
  credentialRef: "凭据引用",
  organization: "组织",
  supportsReasoning: "支持思考",
  protocol: "协议",
  level: "思考等级",
  system: "系统提示词",
  user: "用户提示词",
  variables: "变量（JSON）",
  maxMessages: "最大消息数",
  maxContextTokens: "最大估算 Token",
  overflow: "溢出策略",
  builtins: "内置工具",
  namespace: "命名空间",
  transport: "传输方式",
  command: "命令",
  args: "参数（JSON 数组）",
  cwd: "工作目录",
  env: "环境变量（KEY=VALUE）",
  url: "服务地址",
  headers: "请求头（JSON）",
  skillId: "技能 ID",
  timeout: "超时（毫秒）",
  assets: "媒体资源",
  mode: "处理模式",
  transcript: "转写文本",
  maxDimension: "最大边长",
  detail: "细节等级",
  frameIntervalMs: "抽帧间隔（毫秒）",
  maxFrames: "最大帧数",
  startMs: "开始时间（毫秒）",
  endMs: "结束时间（毫秒）",
  maxPages: "最大页数",
};

const OPTION_TEXT: Record<string, string> = {
  none: "关闭",
  off: "关闭",
  auto: "自动",
  low: "低",
  medium: "中",
  high: "高",
  xhigh: "极高",
  native: "原生",
  transcribed: "转写文本",
  frames: "抽帧",
  extracted: "文本提取",
  trim_oldest: "裁剪最早消息",
  error: "报错",
  stdio: "stdio",
  http: "Streamable HTTP",
};

interface I18nValue {
  locale: Locale;
  setLocale: (locale: Locale) => void;
  tx: (zh: string, en: string) => string;
  nodeTitle: (spec: NodeSpec) => string;
  nodeDescription: (spec: NodeSpec) => string;
  portLabel: (port: PortSpec) => string;
  paramLabel: (name: string, fallback: string) => string;
  optionLabel: (option: ParamOption) => string;
  groupFor: (spec: NodeSpec) => LibraryGroupId;
  groupLabel: (group: LibraryGroupId) => string;
  groupIcon: (group: LibraryGroupId) => string;
}

const I18nContext = createContext<I18nValue | null>(null);
const STORAGE_KEY = "lingxi.locale";

function readLocale(): Locale {
  if (typeof window === "undefined") return "zh-CN";
  return window.localStorage.getItem(STORAGE_KEY) === "en" ? "en" : "zh-CN";
}

export function I18nProvider({ children }: { children: ReactNode }) {
  const [locale, setLocaleState] = useState<Locale>(readLocale);

  const setLocale = useCallback((next: Locale) => {
    setLocaleState(next);
    if (typeof window !== "undefined") window.localStorage.setItem(STORAGE_KEY, next);
  }, []);

  useEffect(() => {
    document.documentElement.lang = locale === "en" ? "en" : "zh-CN";
  }, [locale]);

  const value = useMemo<I18nValue>(() => {
    const tx = (zh: string, en: string) => (locale === "en" ? en : zh);
    const groupFor = (spec: NodeSpec): LibraryGroupId =>
      GROUP_BY_KIND[spec.kind] ?? CATEGORY_FALLBACK[spec.category] ?? "data-processing";
    return {
      locale,
      setLocale,
      tx,
      nodeTitle: (spec) => (locale === "en" ? spec.title : NODE_TEXT[spec.kind]?.title ?? spec.title),
      nodeDescription: (spec) =>
        locale === "en" ? spec.description : NODE_TEXT[spec.kind]?.description ?? spec.description,
      portLabel: (port) => (locale === "en" ? port.label : PORT_TEXT[port.name] ?? port.label),
      paramLabel: (name, fallback) => (locale === "en" ? fallback : PARAM_TEXT[name] ?? fallback),
      optionLabel: (option) => (locale === "en" ? option.label : OPTION_TEXT[option.value] ?? option.label),
      groupFor,
      groupLabel: (group) => {
        const meta = LIBRARY_GROUPS.find((entry) => entry.id === group);
        if (!meta) return group;
        return locale === "en" ? meta.en : meta.zh;
      },
      groupIcon: (group) => LIBRARY_GROUPS.find((entry) => entry.id === group)?.icon ?? "•",
    };
  }, [locale, setLocale]);

  return <I18nContext.Provider value={value}>{children}</I18nContext.Provider>;
}

export function useI18n(): I18nValue {
  const value = useContext(I18nContext);
  if (!value) throw new Error("useI18n must be used inside I18nProvider");
  return value;
}
