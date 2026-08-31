# Topic: Approval Request Workflow (稟議申請システム)

An approval ("ringi") workflow where users may belong to multiple departments at the same time.
The core modelling challenge is that a role (member vs. manager) is **not** an attribute of a user,
but of a *(user, department)* pair.

## 1. Entities and attributes

### Department
- The system contains multiple departments.

### User
- The system contains multiple users.

### Affiliation (membership and role)
- A user belongs to one or more departments (concurrent affiliations are allowed).
- A role (`Member` or `Manager`) is defined for a **(user, department) pair**, not for a user alone.
  - Example: user A is a `Manager` of department X and, at the same time, a `Member` of department Y.
- Every department has at least one `Manager`.

### Request
| Attribute | Description |
| --- | --- |
| author | The user who created the request. |
| target department | The single department the request is submitted to. The author must belong to it. Even when the author has multiple affiliations, exactly one target department is fixed per request. |
| status | Current status of the request. |

## 2. Status model

| Status | Description | Terminal |
| --- | --- | --- |
| `Draft` | Being created by the author; not submitted yet. | |
| `Pending` | Submitted; waiting for approval by a manager of the target department. | |
| `Returned` | A manager judged that changes are needed and sent it back to the author. | |
| `Approved` | Approved by a manager of the target department. | yes |
| `Rejected` | Rejected by a manager of the target department. | yes |

```
            submit                 approve
  Draft ─────────────▶ Pending ─────────────▶ Approved
    ▲                   │  │      reject
    │                   │  └─────────────────▶ Rejected
    │          return   │
  Returned ◀────────────┘
    │  submit (resubmit)
    └────────────────▶ Pending
```

## 3. Access control

Permissions are decided by the combination of the actor, the target department of the request,
and the actor's role *in that department*.

### Read
- R1: A user can read every request whose target department is one of the departments the user belongs to.
- R2: A user can never read a request whose target department is one the user does not belong to.

### Update
- U1 (author): The author can edit their own request only while its status is `Draft` or `Returned`.
- U2 (other members): A request created by another regular member cannot be edited, even within the same department.
- U3 (manager): A manager of the target department can edit the request while its status is `Draft`, `Returned` or `Pending`.

## 4. Actions and state transitions

### A. Create request
- Actor: any user.
- Input: the target department.
- Precondition: the actor belongs to the given target department.
- Postcondition: a new request exists with status `Draft`, the actor as author and the given department as target.

### B. Edit request
- Actor: a user.
- Precondition: either
  - the actor is the author and the status is `Draft` or `Returned`, or
  - the actor is a manager of the target department and the status is `Draft`, `Returned` or `Pending`.
- Postcondition: the content of the request is updated; the status is unchanged.

### C. Submit / resubmit request
- Actor: the author of the request.
- Precondition: the status is `Draft` or `Returned`.
- Postcondition: the status becomes `Pending`.

### D. Approve request
- Actor: a user.
- Precondition: the status is `Pending` and the actor is a manager of the target department.
  - Self-approval is allowed: even if the actor is the author, approval is permitted as long as the actor is a manager of the target department.
- Postcondition: the status becomes `Approved`.

### E. Reject request
- Actor: a user.
- Precondition: the status is `Pending` and the actor is a manager of the target department.
- Postcondition: the status becomes `Rejected`.

### F. Return request
- Actor: a user.
- Precondition: the status is `Pending` and the actor is a manager of the target department.
- Postcondition: the status becomes `Returned`.

## 5. Properties to verify (assertions)

- **P1 — Separation of permissions across affiliations**: a user who is a `Manager` of department X and a
  `Member` of department Y must not be able to approve their own request targeting department Y.
  Approval authority depends solely on the actor's role in the target department.
- **P2 — Terminal states are stable**: once a request is `Approved` or `Rejected`, no action can move it to another status.
- **P3 — No orphan requests**: for every request there exists at least one user (a manager of its target department)
  who can approve, reject or return it.

## 6. Modelling notes

- Model roles as a relation over `(User, Department)`. Attaching a role to a user alone loses the essence of the topic (P1).
- "Every department has at least one manager" is an invariant and is the premise of P3.
- Self-approval (see D) does not contradict P1: the former covers an actor who is a manager of the target department,
  the latter an actor who is only a regular member there.
- Read/update permissions are predicates that do not change state, so they can be expressed separately from the action preconditions.
