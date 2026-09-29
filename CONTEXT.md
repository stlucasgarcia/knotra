# Knotra

Knotra is an embedded agent harness for background work within a host application.

## Language

**Host application**:
The application embedding Knotra. It supplies the initial work requests and controls access to its business operations.

**Agent definition**:
The configuration describing an agent's behavior and available tools, distinct from any individual execution.

**Execution**:
One accepted work request performed using a particular agent definition. Multiple executions may use the same definition.
_Avoid_: Agent (when referring to one execution)

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
