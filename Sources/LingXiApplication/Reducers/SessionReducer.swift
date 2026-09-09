import Foundation
import LingXiProtocol
import LingXiClient

/// Session 内部语义事实归纳器（Reducer）。
/// 严格保证产品状态仅由权威 Snapshot、Semantic Event、Stream Delivery 和 ConnectionState 驱动。
public enum SessionReducer {

    // MARK: - Semantic Event 驱动
    public static func reduce(
        state: inout SessionViewState,
        event: SessionEventEnvelope,
        connectionState: ConnectionState
    ) {
        state.updatedAt = event.timestamp

        switch event.payload {
        // MARK: 1. Turn & Message
        case let .turnCreated(snapshot):
            state.turns[snapshot.turnID] = snapshot
            if !state.turnOrder.contains(snapshot.turnID) {
                state.turnOrder.append(snapshot.turnID)
            }
            let message = snapshot.userMessage
            state.appendCommittedNode(TimelineNode(
                id: .message(message.messageID),
                timestamp: message.createdAt,
                kind: .message(MessageNode(
                    messageID: message.messageID,
                    role: message.role,
                    content: message.text,
                    isStreaming: false,
                    isFinal: true,
                    citations: message.attachments
                ))
            ))
            if state.activeRootRunID != nil {
                // 如果已有活动中的 Root Run，新 Turn 严格标明为 queued
                if !state.queuedTurns.contains(snapshot.turnID) {
                    state.queuedTurns.append(snapshot.turnID)
                }
            } else {
                state.activeTurnID = snapshot.turnID
            }

        case let .userMessageCommitted(message):
            let nodeID = TimelineNodeID.message(message.messageID)
            let msgNode = MessageNode(
                messageID: message.messageID,
                role: message.role,
                content: message.text,
                isStreaming: false,
                isFinal: true
            )
            state.appendCommittedNode(TimelineNode(id: nodeID, timestamp: message.createdAt, kind: .message(msgNode)))

        case let .assistantMessageStarted(messageID, streamID):
            state.messageIDByStream[streamID] = messageID
            // Do not insert an empty assistant node. The first real text frame or
            // committed message determines its semantic position in the timeline.

        case let .assistantMessageCommitted(messageID, content, _):
            let modelStepID = event.causal.modelStepID
            let nodeID = TimelineNodeID.message(messageID, modelStepID: modelStepID)
            let fallbackNodeID = TimelineNodeID.message(messageID)
            let targetID = state.node(for: nodeID) != nil ? nodeID : (state.node(for: fallbackNodeID) != nil ? fallbackNodeID : nodeID)
            if state.node(for: targetID) != nil {
                state.updateNode(id: targetID) { node in
                    if case var .message(m) = node.kind {
                        m.content = content
                        m.isStreaming = false
                        m.isFinal = true
                        node.kind = .message(m)
                    }
                }
                if let finalNode = state.node(for: targetID) {
                    state.appendCommittedNode(finalNode)
                }
            } else {
                let msgNode = MessageNode(
                    messageID: messageID,
                    role: .assistant,
                    content: content,
                    isStreaming: false,
                    isFinal: true
                )
                state.appendCommittedNode(TimelineNode(id: nodeID, timestamp: event.timestamp, kind: .message(msgNode), modelStepID: modelStepID))
            }

        case let .turnCompleted(turnID, _):
            updateTurn(state: &state, turnID: turnID, status: .completed, completedAt: event.timestamp)
            state.queuedTurns.removeAll { $0 == turnID }
            if state.activeTurnID == turnID {
                state.activeTurnID = nil
            }
            state.hasActiveError = false
            finalizeActiveTools(state: &state)
            finalizeActiveThinking(state: &state, timestamp: event.timestamp)

        case let .turnFailed(turnID, error):
            updateTurn(state: &state, turnID: turnID, status: .failed, completedAt: event.timestamp)
            state.queuedTurns.removeAll { $0 == turnID }
            if state.activeTurnID == turnID {
                state.activeTurnID = nil
            }
            state.hasActiveError = true
            finalizeActiveTools(state: &state)
            finalizeActiveThinking(state: &state, timestamp: event.timestamp)
            let errNodeID = TimelineNodeID.error(error.id)
            state.appendNode(TimelineNode(id: errNodeID, timestamp: event.timestamp, kind: .error(ErrorNode(from: error))))

        // MARK: 2. Run
        case let .runCreated(snapshot):
            state.runs[snapshot.runID] = snapshot
            if state.activeRootRunID == nil,
                snapshot.parentRunID == nil,
                snapshot.status == .running || snapshot.status == .paused {
                state.activeRootRunID = snapshot.runID
                updateTurn(state: &state, turnID: snapshot.turnID, status: .running, rootRunID: snapshot.runID)
            } else if snapshot.status == .queued, snapshot.parentRunID == nil {
                updateTurn(state: &state, turnID: snapshot.turnID, status: .queued, rootRunID: snapshot.runID)
                if !state.queuedTurns.contains(snapshot.turnID) {
                    state.queuedTurns.append(snapshot.turnID)
                }
            }

        case let .runQueued(runID):
            let turnID = event.causal.turnID ?? state.runs[runID]?.turnID
            if let turnID {
                updateTurn(state: &state, turnID: turnID, status: .queued, rootRunID: runID)
                if !state.queuedTurns.contains(turnID) {
                    state.queuedTurns.append(turnID)
                }
            }
            if state.runs[runID] != nil {
                updateRun(state: &state, runID: runID, status: .queued)
            }

        case let .runStarted(runID):
            if state.runs[runID]?.parentRunID == nil,
                state.activeRootRunID == nil || state.activeRootRunID == runID {
                state.activeRootRunID = runID
                if let snapshot = state.runs[runID] {
                    let turnID = snapshot.turnID
                    updateRun(state: &state, runID: runID, status: .running)
                    updateTurn(state: &state, turnID: turnID, status: .running, rootRunID: runID)
                    state.activeTurnID = turnID
                    state.queuedTurns.removeAll { $0 == turnID }
                }
            }

        case let .runPaused(runID, _):
            updateRun(state: &state, runID: runID, status: .paused)

        case let .runResumed(runID):
            updateRun(state: &state, runID: runID, status: .running)

        case let .runCompleted(runID, terminalReason):
            let turnID = state.runs[runID]?.turnID
            updateRun(state: &state, runID: runID, status: .completed, completedAt: event.timestamp, terminalReason: terminalReason)
            if let turnID { updateTurn(state: &state, turnID: turnID, status: .completed, completedAt: event.timestamp) }
            if state.activeRootRunID == runID {
                state.activeRootRunID = nil
            }
            if let turnID, state.activeTurnID == turnID {
                state.activeTurnID = nil
            }
            state.activeProviderRequestState = nil
            state.activeProviderRequestID = nil
            state.activeSubagentRunIDs.remove(runID)
            finalizeActiveTools(state: &state)
            finalizeActiveThinking(state: &state, timestamp: event.timestamp)
            let termNodeID = TimelineNodeID.runTerminal(runID)
            state.appendNode(TimelineNode(id: termNodeID, timestamp: event.timestamp, kind: .runTerminal(RunTerminalNode(runID: runID, terminalReason: terminalReason))))

        case let .runFailed(runID, error):
            let turnID = state.runs[runID]?.turnID
            updateRun(state: &state, runID: runID, status: .failed, completedAt: event.timestamp, terminalReason: .runtimeFailure)
            if let turnID { updateTurn(state: &state, turnID: turnID, status: .failed, completedAt: event.timestamp) }
            state.hasActiveError = true
            if state.activeRootRunID == runID {
                state.activeRootRunID = nil
            }
            if let turnID, state.activeTurnID == turnID {
                state.activeTurnID = nil
            }
            state.activeProviderRequestState = nil
            state.activeProviderRequestID = nil
            state.activeSubagentRunIDs.remove(runID)
            finalizeActiveTools(state: &state)
            finalizeActiveThinking(state: &state, timestamp: event.timestamp)
            let termNodeID = TimelineNodeID.runTerminal(runID)
            state.appendNode(TimelineNode(id: termNodeID, timestamp: event.timestamp, kind: .runTerminal(RunTerminalNode(runID: runID, terminalReason: .runtimeFailure))))
            let errNodeID = TimelineNodeID.error(error.id)
            state.appendNode(TimelineNode(id: errNodeID, timestamp: event.timestamp, kind: .error(ErrorNode(from: error))))

        case let .runCancelled(runID, _):
            let turnID = state.runs[runID]?.turnID
            updateRun(state: &state, runID: runID, status: .cancelled, completedAt: event.timestamp, terminalReason: .userCancelled)
            if let turnID { updateTurn(state: &state, turnID: turnID, status: .cancelled, completedAt: event.timestamp) }
            if state.activeRootRunID == runID {
                state.activeRootRunID = nil
            }
            if let turnID, state.activeTurnID == turnID {
                state.activeTurnID = nil
            }
            state.activeProviderRequestState = nil
            state.activeProviderRequestID = nil
            state.activeSubagentRunIDs.remove(runID)
            finalizeActiveTools(state: &state)
            finalizeActiveThinking(state: &state, timestamp: event.timestamp)
            let termNodeID = TimelineNodeID.runTerminal(runID)
            state.appendNode(TimelineNode(id: termNodeID, timestamp: event.timestamp, kind: .runTerminal(RunTerminalNode(runID: runID, terminalReason: .userCancelled))))

        // MARK: 3. ModelStep & Thinking
        case let .modelStepStarted(stepID, visibleReasoningStreamID, _):
            if state.thinkingNodes[stepID]?.isComplete == true {
                break
            }
            if let visibleReasoningStreamID {
                state.thinkingStepIDByStream[visibleReasoningStreamID] = stepID
            }
            state.activeThinkingStepID = stepID
            if state.thinkingNodes[stepID] == nil {
                let thinking = ThinkingNode(stepID: stepID, title: "Thinking", isStreaming: true, startedAt: event.timestamp)
                state.thinkingNodes[stepID] = thinking
                state.appendNode(TimelineNode(id: TimelineNodeID.thinking(stepID), timestamp: event.timestamp, kind: .thinking(thinking), modelStepID: stepID))
            }

        case let .modelStepCompleted(stepID, _, metadata):
            if var thinking = state.thinkingNodes[stepID] {
                thinking.isStreaming = false
                thinking.isComplete = true
                thinking.outputMetadata = metadata
                thinking.completedAt = event.timestamp
                if let start = thinking.startedAt {
                    let s = event.timestamp.timeIntervalSince(start)
                    thinking.duration = .milliseconds(max(0, s * 1000.0))
                }
                state.thinkingNodes[stepID] = thinking
                let nodeID = TimelineNodeID.thinking(stepID)
                state.updateNode(id: nodeID) { node in
                    node.kind = .thinking(thinking)
                }
            }
            if state.activeThinkingStepID == stepID {
                state.activeThinkingStepID = nil
            }
            if let meta = metadata {
                let metrics = MessageMetrics(
                    model: meta.model,
                    durationMs: meta.durationMs,
                    firstTokenMs: meta.firstTokenMs,
                    tokenRate: meta.tokenRate,
                    totalTokens: meta.totalTokens,
                    completedAt: meta.completedAt ?? event.timestamp
                )
                for idx in state.timelineNodes.indices.reversed() {
                    if case var .message(m) = state.timelineNodes[idx].kind, m.role == .assistant {
                        if state.timelineNodes[idx].modelStepID == stepID || state.timelineNodes[idx].modelStepID == nil {
                            m.metrics = metrics
                            m.isFinal = true
                            m.isStreaming = false
                            state.timelineNodes[idx].kind = .message(m)
                            break
                        }
                    }
                }
            }

        case let .modelStepFailed(stepID, error):
            if var thinking = state.thinkingNodes[stepID] {
                thinking.isStreaming = false
                thinking.isComplete = true
                state.thinkingNodes[stepID] = thinking
                let nodeID = TimelineNodeID.thinking(stepID)
                state.updateNode(id: nodeID) { node in
                    node.kind = .thinking(thinking)
                }
            }
            if state.activeThinkingStepID == stepID {
                state.activeThinkingStepID = nil
            }
            state.hasActiveError = true
            let errNodeID = TimelineNodeID.error(error.id)
            state.appendNode(TimelineNode(id: errNodeID, timestamp: event.timestamp, kind: .error(ErrorNode(from: error))))

        // MARK: 4. Tool Lifecycle
        case let .toolRequested(invocation):
            let callID = invocation.callID
            let modelStepID = event.causal.modelStepID
            if let stepID = modelStepID ?? state.activeThinkingStepID {
                completeThinking(state: &state, stepID: stepID, timestamp: event.timestamp)
            }
            let nodeID = TimelineNodeID.tool(callID, modelStepID: modelStepID)
            var toolNode = state.toolNodes[callID] ?? ToolNode(
                callID: callID,
                toolName: invocation.displayName,
                argumentsJSON: invocation.argumentsSummary,
                phase: .requested,
                modelStepID: modelStepID,
                requestedAt: event.timestamp
            )
            toolNode.modelStepID = modelStepID
            toolNode.requestedAt = event.timestamp
            state.toolNodes[callID] = toolNode
            state.appendNode(TimelineNode(id: nodeID, timestamp: event.timestamp, kind: .tool(toolNode), modelStepID: modelStepID))

        case let .toolWaitingForPermission(callID, permissionID):
            let modelStepID = event.causal.modelStepID ?? state.toolNodes[callID]?.modelStepID
            let nodeID = TimelineNodeID.tool(callID, modelStepID: modelStepID)
            var tool = ensureToolNode(state: &state, callID: callID, timestamp: event.timestamp, modelStepID: modelStepID)
            tool.phase = .waitingPermission
            tool.permissionID = permissionID
            state.toolNodes[callID] = tool
            state.updateNode(id: nodeID) { node in
                node.kind = .tool(tool)
            }

        case let .toolScheduled(callID):
            let modelStepID = event.causal.modelStepID ?? state.toolNodes[callID]?.modelStepID
            let nodeID = TimelineNodeID.tool(callID, modelStepID: modelStepID)
            var tool = ensureToolNode(state: &state, callID: callID, timestamp: event.timestamp, modelStepID: modelStepID)
            tool.phase = .scheduled
            tool.admittedAt = event.timestamp
            state.toolNodes[callID] = tool
            state.updateNode(id: nodeID) { node in
                node.kind = .tool(tool)
            }

        case let .toolRunning(callID, stdoutStreamID, stderrStreamID):
            if let stdoutStreamID {
                state.toolCallIDByStream[stdoutStreamID] = callID
            }
            if let stderrStreamID {
                state.toolCallIDByStream[stderrStreamID] = callID
            }
            let modelStepID = event.causal.modelStepID ?? state.toolNodes[callID]?.modelStepID
            let nodeID = TimelineNodeID.tool(callID, modelStepID: modelStepID)
            state.activeToolCallIDs.insert(callID)
            var tool = ensureToolNode(state: &state, callID: callID, timestamp: event.timestamp, modelStepID: modelStepID)
            tool.phase = .running
            tool.executorStartedAt = event.timestamp
            state.toolNodes[callID] = tool
            state.updateNode(id: nodeID) { node in
                node.kind = .tool(tool)
            }

        case let .toolCompleted(callID, result, _, _):
            guard result.callID == callID else { break }
            ToolLifecycleTrace.record(callID: callID, .applicationProjectionReceived)
            let modelStepID = event.causal.modelStepID ?? state.toolNodes[callID]?.modelStepID
            let nodeID = TimelineNodeID.tool(callID, modelStepID: modelStepID)
            state.activeToolCallIDs.remove(callID)
            var tool = ensureToolNode(state: &state, callID: callID, timestamp: event.timestamp, modelStepID: modelStepID)
            tool.phase = .completed
            tool.result = result
            tool.executorFinishedAt = event.timestamp
            tool.resultCommittedAt = event.timestamp
            tool.projectionReceivedAt = event.timestamp
            if tool.executorStartedAt == nil {
                let execMs = result.timing.executionMilliseconds
                if execMs > 0 {
                    tool.executorStartedAt = event.timestamp.addingTimeInterval(-execMs / 1000.0)
                }
            }
            state.toolNodes[callID] = tool
            state.updateNode(id: nodeID) { node in
                node.kind = .tool(tool)
            }

        case let .toolFailed(callID, error, _, _):
            let modelStepID = event.causal.modelStepID ?? state.toolNodes[callID]?.modelStepID
            let nodeID = TimelineNodeID.tool(callID, modelStepID: modelStepID)
            state.activeToolCallIDs.remove(callID)
            state.hasActiveError = true
            var tool = ensureToolNode(state: &state, callID: callID, timestamp: event.timestamp, modelStepID: modelStepID)
            tool.phase = .failed
            tool.error = error
            tool.executorFinishedAt = event.timestamp
            state.toolNodes[callID] = tool
            state.updateNode(id: nodeID) { node in
                node.kind = .tool(tool)
            }

        case let .toolCancelled(callID, _, _):
            let modelStepID = event.causal.modelStepID ?? state.toolNodes[callID]?.modelStepID
            let nodeID = TimelineNodeID.tool(callID, modelStepID: modelStepID)
            state.activeToolCallIDs.remove(callID)
            var tool = ensureToolNode(state: &state, callID: callID, timestamp: event.timestamp, modelStepID: modelStepID)
            tool.phase = .cancelled
            state.toolNodes[callID] = tool
            state.updateNode(id: nodeID) { node in
                node.kind = .tool(tool)
            }

        case let .toolExecutionStateUnknown(callID):
            state.activeToolCallIDs.remove(callID)
            state.hasActiveError = true

        // MARK: 5. HITL Interaction
        case let .interactionRequested(snapshot):
            if !state.pendingInteractions.contains(where: { $0.interactionID == snapshot.interactionID }) {
                state.pendingInteractions.append(snapshot)
            }
            state.activeInteraction = snapshot
            let nodeID = TimelineNodeID.interaction(snapshot.interactionID)
            state.appendNode(TimelineNode(id: nodeID, timestamp: event.timestamp, kind: .interaction(InteractionNode(from: snapshot))))

        case let .interactionResolved(interactionID, resolution):
            state.pendingInteractions.removeAll { $0.interactionID == interactionID }
            state.activeInteraction = state.pendingInteractions.first
            let nodeID = TimelineNodeID.interaction(interactionID)
            state.updateNode(id: nodeID) { node in
                if case var .interaction(inter) = node.kind {
                    inter.isResolved = true
                    inter.resolution = resolution
                    node.kind = .interaction(inter)
                }
            }

        case let .interactionCancelled(interactionID):
            state.pendingInteractions.removeAll { $0.interactionID == interactionID }
            state.activeInteraction = state.pendingInteractions.first
            let nodeID = TimelineNodeID.interaction(interactionID)
            state.updateNode(id: nodeID) { node in
                if case var .interaction(inter) = node.kind {
                    inter.isResolved = true
                    node.kind = .interaction(inter)
                }
            }

        // MARK: 6. Subagents
        case let .subagentCreated(runID, parentRunID):
            state.activeSubagentRunIDs.insert(runID)
            let subNode = SubagentNode(runID: runID, parentRunID: parentRunID, status: "created")
            state.subagents[runID] = subNode
            let nodeID = TimelineNodeID.subagent(runID)
            state.appendNode(TimelineNode(id: nodeID, timestamp: event.timestamp, kind: .subagent(subNode)))

        case let .subagentStateChanged(runID, status):
            if var subNode = state.subagents[runID] {
                subNode.status = status
                state.subagents[runID] = subNode
                let nodeID = TimelineNodeID.subagent(runID)
                state.updateNode(id: nodeID) { node in
                    node.kind = .subagent(subNode)
                }
            }

        case let .subagentTerminal(runID, terminalReason):
            state.activeSubagentRunIDs.remove(runID)
            if var subNode = state.subagents[runID] {
                subNode.status = terminalReason.rawValue
                subNode.terminalReason = terminalReason
                state.subagents[runID] = subNode
                let nodeID = TimelineNodeID.subagent(runID)
                state.updateNode(id: nodeID) { node in
                    node.kind = .subagent(subNode)
                }
            }

        // MARK: 7. Context
        case let .contextStateChanged(snapshot):
            state.contextState = snapshot
            state.isPaging = false

        case let .contextPolicyChanged(snapshot):
            state.contextPolicy = snapshot

        case let .contextCompacted(snapshot):
            state.contextCompacted = snapshot
            state.isPaging = false

        // MARK: 8. Provider Request
        case let .providerRequestStateChanged(requestID, pState):
            state.activeProviderRequestID = requestID
            state.activeProviderRequestState = pState

        case .unknown:
            break
        }

        // 重新投影高层产品状态
        state.recalculateStatus(connectionState: connectionState)
    }

    // MARK: - Stream Frame 驱动
    public static func reduceStreamFrame(
        state: inout SessionViewState,
        frame: StreamFrame,
        connectionState: ConnectionState
    ) {
        guard let text = frame.textPayload, !text.isEmpty else { return }
        switch frame.kind {
        case .assistantText:
            if let stepID = frame.owner.modelStepID ?? state.activeThinkingStepID {
                completeThinking(state: &state, stepID: stepID, timestamp: Date())
            }
            if let messageID = state.messageIDByStream[frame.streamID] {
                let modelStepID = frame.owner.modelStepID
                let nodeID = TimelineNodeID.message(messageID, modelStepID: modelStepID)
                if state.node(for: nodeID) != nil {
                    state.updateNode(id: nodeID) { node in
                        if case var .message(m) = node.kind {
                            guard !m.isFinal else { return }
                            m.content += text
                            m.isStreaming = true
                            node.kind = .message(m)
                        }
                    }
                    if let updated = state.node(for: nodeID) {
                        state.updateActiveCell(updated)
                    }
                } else {
                    let newNode = TimelineNode(
                        id: nodeID,
                        kind: .message(MessageNode(
                            messageID: messageID,
                            role: .assistant,
                            content: text,
                            isStreaming: true,
                            isFinal: false
                        )),
                        modelStepID: modelStepID
                    )
                    state.updateActiveCell(newNode)
                }
            }

        case .visibleReasoning, .reasoningSummary:
            if let stepID = state.thinkingStepIDByStream[frame.streamID] ?? frame.owner.modelStepID {
                let nodeID = TimelineNodeID.thinking(stepID)
                var thinking = state.thinkingNodes[stepID] ?? ThinkingNode(stepID: stepID, title: "Thinking", startedAt: Date())
                if thinking.startedAt == nil {
                    thinking.startedAt = Date()
                }
                thinking.content += text
                thinking.isStreaming = true
                thinking.isComplete = false
                state.thinkingNodes[stepID] = thinking
                state.activeThinkingStepID = stepID
                if state.node(for: nodeID) == nil {
                    let newNode = TimelineNode(id: nodeID, kind: .thinking(thinking), modelStepID: stepID)
                    state.updateActiveCell(newNode)
                } else {
                    state.updateNode(id: nodeID) { node in
                        node.kind = .thinking(thinking)
                    }
                    if let updated = state.node(for: nodeID) {
                        state.updateActiveCell(updated)
                    }
                }
            }

        case .stdout, .toolLiveOutput:
            if let callID = state.toolCallIDByStream[frame.streamID] ?? frame.owner.toolCallID {
                let modelStepID = frame.owner.modelStepID ?? state.toolNodes[callID]?.modelStepID
                let nodeID = TimelineNodeID.tool(callID, modelStepID: modelStepID)
                if var tool = state.toolNodes[callID] {
                    tool.stdout += text
                    state.toolNodes[callID] = tool
                    state.updateNode(id: nodeID) { node in
                        node.kind = .tool(tool)
                    }
                    if let updated = state.node(for: nodeID) {
                        state.updateActiveCell(updated)
                    }
                }
            }

        case .stderr:
            if let callID = state.toolCallIDByStream[frame.streamID] ?? frame.owner.toolCallID {
                let modelStepID = frame.owner.modelStepID ?? state.toolNodes[callID]?.modelStepID
                let nodeID = TimelineNodeID.tool(callID, modelStepID: modelStepID)
                if var tool = state.toolNodes[callID] {
                    tool.stderr += text
                    state.toolNodes[callID] = tool
                    state.updateNode(id: nodeID) { node in
                        node.kind = .tool(tool)
                    }
                    if let updated = state.node(for: nodeID) {
                        state.updateActiveCell(updated)
                    }
                }
            }

        case .unknown:
            break
        }

        state.recalculateStatus(connectionState: connectionState)
    }

    // MARK: - Snapshot Resync 重建
    public static func reduceSnapshot(
        state: inout SessionViewState,
        snapshot: SessionSnapshot,
        connectionState: ConnectionState
    ) {
        // Snapshot replaces every projection fact. Timeline is rebuilt only from the
        // snapshot's authoritative semantic activity window, never local timestamps.
        state = SessionViewState(
            sessionID: snapshot.sessionID,
            title: snapshot.info.title,
            mode: snapshot.agentMode,
            createdAt: snapshot.info.createdAt,
            updatedAt: snapshot.info.updatedAt,
            reasoningEffort: snapshot.info.reasoningEffort
        )
        state.contextState = snapshot.contextState
            state.pendingInteractions = snapshot.pendingInteractions
            state.activeInteraction = snapshot.pendingInteractions.first
            state.permissionConfiguration = snapshot.permissionConfiguration

        for turn in snapshot.recentTurns {
            state.turns[turn.turnID] = turn
            state.turnOrder.append(turn.turnID)
            if turn.status == .queued {
                state.queuedTurns.append(turn.turnID)
            }
        }
        if let rootRun = snapshot.activeRootRun {
            state.runs[rootRun.runID] = rootRun
            state.activeRootRunID = rootRun.runID
            state.activeTurnID = rootRun.turnID
            state.queuedTurns.removeAll { $0 == rootRun.turnID }
        }
        for childRun in snapshot.activeChildRuns {
            state.activeSubagentRunIDs.insert(childRun.runID)
            if let parentRunID = childRun.parentRunID {
                state.subagents[childRun.runID] = SubagentNode(
                    runID: childRun.runID,
                    parentRunID: parentRunID,
                    status: childRun.status.rawValue
                )
            }
        }
        for step in snapshot.activeModelSteps {
            if let streamID = step.visibleReasoningStreamID {
                state.thinkingStepIDByStream[streamID] = step.stepID
            }
        }
        for tool in snapshot.recentToolInvocations {
            let phase = ToolExecutionPhase(rawValue: tool.state.rawValue) ?? .requested
            state.toolNodes[tool.callID] = ToolNode(
                callID: tool.callID,
                toolName: tool.displayName,
                argumentsJSON: tool.argumentsSummary,
                phase: phase,
                error: tool.error
            )
            if phase == .running {
                state.activeToolCallIDs.insert(tool.callID)
            }
        }
        for event in snapshot.recentEvents {
            reduce(state: &state, event: event, connectionState: connectionState)
        }
        state.updatedAt = snapshot.info.updatedAt
        state.recalculateStatus(connectionState: connectionState)
    }

    private static func updateRun(
        state: inout SessionViewState,
        runID: RunID,
        status: RunStatus,
        completedAt: Date? = nil,
        terminalReason: TerminalReason? = nil
    ) {
        guard let run = state.runs[runID] else { return }
        state.runs[runID] = RunSnapshot(
            runID: run.runID,
            sessionID: run.sessionID,
            turnID: run.turnID,
            rootRunID: run.rootRunID,
            parentRunID: run.parentRunID,
            status: status,
            model: run.model,
            createdAt: run.createdAt,
            completedAt: completedAt ?? run.completedAt,
            terminalReason: terminalReason ?? run.terminalReason
        )
    }

    private static func ensureToolNode(
        state: inout SessionViewState,
        callID: ToolCallID,
        timestamp: Date,
        modelStepID: ModelStepID? = nil
    ) -> ToolNode {
        if let tool = state.toolNodes[callID] {
            return tool
        }
        var tool = ToolNode(callID: callID, toolName: "Tool")
        tool.modelStepID = modelStepID
        tool.requestedAt = timestamp
        state.toolNodes[callID] = tool
        state.appendNode(TimelineNode(id: .tool(callID, modelStepID: modelStepID), timestamp: timestamp, kind: .tool(tool), modelStepID: modelStepID))
        return tool
    }

    private static func updateTurn(
        state: inout SessionViewState,
        turnID: TurnID,
        status: TurnStatus,
        rootRunID: RunID? = nil,
        completedAt: Date? = nil
    ) {
        guard let turn = state.turns[turnID] else { return }
        state.turns[turnID] = TurnSnapshot(
            turnID: turn.turnID,
            sessionID: turn.sessionID,
            userMessage: turn.userMessage,
            executionIntent: turn.executionIntent,
            status: status,
            rootRunID: rootRunID ?? turn.rootRunID,
            createdAt: turn.createdAt,
            completedAt: completedAt ?? turn.completedAt
        )
    }

    private static func finalizeActiveTools(state: inout SessionViewState) {
        for callID in state.activeToolCallIDs {
            guard var tool = state.toolNodes[callID], tool.phase == .running else { continue }
            tool.phase = .cancelled
            state.toolNodes[callID] = tool
            let nodeID = TimelineNodeID.tool(callID, modelStepID: tool.modelStepID)
            state.updateNode(id: nodeID) { node in
                node.kind = .tool(tool)
            }
        }
        state.activeToolCallIDs.removeAll()
    }

    private static func completeThinking(state: inout SessionViewState, stepID: ModelStepID, timestamp: Date) {
        guard var thinking = state.thinkingNodes[stepID], !thinking.isComplete else { return }
        thinking.isStreaming = false
        thinking.isComplete = true
        thinking.completedAt = timestamp
        if let started = thinking.startedAt {
            let s = timestamp.timeIntervalSince(started)
            thinking.duration = .milliseconds(max(0, s * 1000.0))
        }
        state.thinkingNodes[stepID] = thinking
        let nodeID = TimelineNodeID.thinking(stepID)
        state.updateNode(id: nodeID) { node in
            node.kind = .thinking(thinking)
        }
        if state.activeThinkingStepID == stepID {
            state.activeThinkingStepID = nil
        }
    }

    private static func finalizeActiveThinking(state: inout SessionViewState, timestamp: Date) {
        if let activeID = state.activeThinkingStepID {
            completeThinking(state: &state, stepID: activeID, timestamp: timestamp)
        }
        for (stepID, thinking) in state.thinkingNodes where !thinking.isComplete {
            completeThinking(state: &state, stepID: stepID, timestamp: timestamp)
        }
    }
}
