# Knotra

Knotra is an embedded agent harness within a host application. Its intended scope includes both background work and user-interactive workflows.

## Language

**Host application**:
The application embedding Knotra. It supplies the initial work requests and controls access to its business operations.

**Agent definition**:
The configuration describing an agent's behavior and available tools, distinct from any individual execution.

**Execution**:
One accepted work request performed using a particular agent definition. Multiple executions may use the same definition.
_Avoid_: Agent (when referring to one execution)

**Conversation**:
An ongoing interaction history that may contain multiple executions. Answering a pending question continues its execution; an independent work request starts another.

**Input request**:
A request for information needed to continue an execution, distinct from permission to perform an action.

**Approval request**:
A request for a human decision on a specific proposed operation and its arguments. Approval does not replace the host application's authorization.

**Human takeover**:
A transfer of control that stops new agent operations until control is explicitly handed back. Operations already dispatched may still complete.

**Presentation request**:
An agent-produced, structured description of an interaction for the host to render through approved components, not arbitrary executable frontend code.

**Trigger**:
An occurrence that causes work to be submitted, such as receipt of an email or a scheduled time.

**Proposed action**:
An agent-produced recommendation that has not itself performed the recommended business operation.

**Execution record**:
The recorded inputs, outputs, and tool interactions of an execution, used to inspect what happened.

**Offline replay**:
An execution using recorded model and tool responses to check harness behavior rather than model quality.

**Model evaluation**:
A fresh model execution against a saved scenario and explicit acceptance checks, with tool interactions isolated from production.
