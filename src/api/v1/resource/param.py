# S1.traceability: {"tis_task_ids": ["PROJECT-7069aaba-547e-4b5f-b792-7516f91cf75b-TASK-t-endpoint-patch-api-v1-resource-id"], "test_definition_ids": ["TD-T-ENDPOINT-PATCH-API-V1-RESOURCE-ID"], "design_entity_ids": [], "operation": "create"}

"""
PATCH /api/v1/resource/{id}

Implements committed endpoint behavior for partial updates on incident-owned
resources with break-glass elevation support.

Scope-limited changes:
  - Only on-call engineers may perform break-glass elevation.
  - Elevation expires after 30 minutes.
  - A structured audit event is written on every elevation attempt.
  - Cash-payment reservation status may be patched (reserved_cash flag).
"""

import logging
import uuid
from datetime import datetime, timedelta, timezone
from typing import Any, Dict, Optional

from django.core.exceptions import ObjectDoesNotExist, PermissionDenied
from django.http import JsonResponse
from django.utils.decorators import method_decorator
from django.views import View
from django.views.decorators.csrf import csrf_exempt

import json

logger = logging.getLogger(__name__)

# ---------------------------------------------------------------------------
# Constants
# ---------------------------------------------------------------------------

BREAK_GLASS_TTL_MINUTES: int = 30

# Allowed top-level fields that a PATCH request may modify.
ALLOWABLE_PATCH_FIELDS = frozenset([
    "status",
    "reserved_cash",
    "break_glass",
])


# ---------------------------------------------------------------------------
# Internal helpers
# ---------------------------------------------------------------------------

def _utcnow() -> datetime:
    """effect: time_read — Return current UTC datetime."""
    return datetime.now(tz=timezone.utc)


def _is_on_call(actor_id: str) -> bool:
    """
    effect: authorization_check
    Determine whether the given actor is currently on-call.

    In production this would query an on-call roster service or database.
    Here we delegate to the project's existing on-call registry table via
    Django ORM.  The import is deferred to avoid circular imports at module
    load time.
    """
    # AG_DECISION: DP-01
    try:
        from django.apps import apps  # noqa: PLC0415
        OnCallRoster = apps.get_model("resource", "OnCallRoster")  # type: ignore[attr-defined]
        return OnCallRoster.objects.filter(
            actor_id=actor_id,
            active=True,
        ).exists()
    except LookupError:
        # Model not yet registered (e.g. during tests without full app setup).
        logger.warning(
            "OnCallRoster model not found; denying break-glass by default."
        )
        return False


def _write_audit_event(
    *,
    incident_id: str,
    reason: str,
    actor_id: str,
    expires_at: datetime,
    resource_id: str,
    granted: bool,
) -> None:
    """
    effect: audit_log_write
    Persist a structured audit event for a break-glass elevation attempt.
    """
    event: Dict[str, Any] = {
        "event_type": "break_glass_elevation",
        "incident_id": incident_id,
        "reason": reason,
        "actor_id": actor_id,
        "expires_at": expires_at.isoformat(),
        "resource_id": resource_id,
        "granted": granted,
        "recorded_at": _utcnow().isoformat(),
    }
    # AG_DECISION: DP-02
    try:
        from django.apps import apps  # noqa: PLC0415
        AuditEvent = apps.get_model("resource", "AuditEvent")  # type: ignore[attr-defined]
        AuditEvent.objects.create(**event)
    except LookupError:
        # Fallback: emit to structured log so the event is never silently lost.
        logger.error(
            "audit_event_fallback",
            extra=event,
        )
    logger.info("break_glass_audit_event", extra=event)


def _load_resource(resource_id: str) -> Any:
    """
    effect: database_read
    Load a resource by primary key.  Raises ObjectDoesNotExist if not found.
    """
    from django.apps import apps  # noqa: PLC0415
    Resource = apps.get_model("resource", "Resource")  # type: ignore[attr-defined]
    return Resource.objects.get(pk=resource_id)


def _save_resource(resource: Any, updates: Dict[str, Any]) -> None:
    """
    effect: database_write
    Apply allowed field updates to a resource and persist.
    """
    for field, value in updates.items():
        setattr(resource, field, value)
    resource.save(update_fields=list(updates.keys()))


# ---------------------------------------------------------------------------
# Break-glass elevation handler
# ---------------------------------------------------------------------------

def _handle_break_glass(
    resource: Any,
    break_glass_payload: Dict[str, Any],
    actor_id: str,
) -> Dict[str, Any]:
    """
    Process a break-glass elevation request embedded in a PATCH body.

    Returns a dict describing the outcome to be merged into the response.
    Raises PermissionDenied if the actor is not on-call.
    """
    incident_id: str = str(break_glass_payload.get("incident_id", ""))
    reason: str = str(break_glass_payload.get("reason", ""))

    # effect: time_read
    now = _utcnow()
    expires_at: datetime = now + timedelta(minutes=BREAK_GLASS_TTL_MINUTES)

    # effect: authorization_check
    on_call: bool = _is_on_call(actor_id)

    # effect: audit_log_write
    _write_audit_event(
        incident_id=incident_id,
        reason=reason,
        actor_id=actor_id,
        expires_at=expires_at,
        resource_id=str(resource.pk),
        granted=on_call,
    )

    # AG_DECISION: DP-03
    if not on_call:
        # AG_DECISION: DP-04
        raise PermissionDenied(
            "Break-glass elevation is restricted to on-call engineers."
        )

    return {
        "break_glass_granted": True,
        "expires_at": expires_at.isoformat(),
        "incident_id": incident_id,
    }


# ---------------------------------------------------------------------------
# Request parsing
# ---------------------------------------------------------------------------

def _parse_json_body(request) -> Dict[str, Any]:  # type: ignore[type-arg]
    """
    effect: http_request_parse
    Parse the JSON body of a Django request.  Returns an empty dict on failure.
    """
    # AG_DECISION: DP-05
    try:
        body = request.body
        # AG_DECISION: DP-06
        if not body:
            return {}
        return json.loads(body)
    except (json.JSONDecodeError, UnicodeDecodeError) as exc:
        logger.warning("patch_body_parse_error: %s", exc)
        return {}


def _extract_actor_id(request) -> str:  # type: ignore[type-arg]
    """
    effect: http_request_parse
    Extract the actor identifier from request headers or session.
    Falls back to an anonymous sentinel so downstream checks can deny cleanly.
    """
    return (
        request.headers.get("X-Actor-Id")
        or request.META.get("HTTP_X_ACTOR_ID", "")
        or "anonymous"
    )


# ---------------------------------------------------------------------------
# Core service function (testable without HTTP layer)
# ---------------------------------------------------------------------------

def patch_resource(
    resource_id: str,
    payload: Dict[str, Any],
    actor_id: str,
) -> Dict[str, Any]:
    """
    Apply a partial update to a resource.

    Returns a dict suitable for JSON serialisation.
    Raises:
        ObjectDoesNotExist  — resource not found
        PermissionDenied    — break-glass attempted by non-on-call actor
        ValueError          — payload contains no recognised fields
    """
    # effect: database_read
    # AG_DECISION: DP-07
    try:
        resource = _load_resource(resource_id)
    except ObjectDoesNotExist:
        # AG_DECISION: DP-08
        raise

    # Separate break-glass from ordinary field updates.
    break_glass_payload: Optional[Dict[str, Any]] = payload.get("break_glass")
    ordinary_updates: Dict[str, Any] = {
        k: v
        for k, v in payload.items()
        if k in ALLOWABLE_PATCH_FIELDS and k != "break_glass"
    }

    response_extra: Dict[str, Any] = {}

    # Handle break-glass elevation first so that audit is always written.
    # AG_DECISION: DP-09
    if break_glass_payload is not None:
        elevation_result = _handle_break_glass(
            resource=resource,
            break_glass_payload=break_glass_payload,
            actor_id=actor_id,
        )
        response_extra.update(elevation_result)

    # Apply ordinary field updates.
    # AG_DECISION: DP-10
    if ordinary_updates:
        # effect: database_write
        _save_resource(resource, ordinary_updates)
    # AG_DECISION: DP-01
    elif break_glass_payload is None:
        # AG_DECISION: DP-01
        raise ValueError(
            "PATCH body must include at least one recognised field: "
            + ", ".join(sorted(ALLOWABLE_PATCH_FIELDS))
        )

    # Reload to return current state.
    # effect: database_read
    # AG_DECISION: DP-02
    try:
        resource.refresh_from_db()
    except Exception:  # noqa: BLE001
        pass  # Non-fatal; return stale snapshot.

    result: Dict[str, Any] = {
        "id": str(resource.pk),
        "updated_at": _utcnow().isoformat(),
    }

    # Merge in any serialisable fields that exist on the model.
    for field in ("status", "reserved_cash"):
        # AG_DECISION: DP-03
        if hasattr(resource, field):
            result[field] = getattr(resource, field)

    result.update(response_extra)
    return result


# ---------------------------------------------------------------------------
# Django view
# ---------------------------------------------------------------------------

@method_decorator(csrf_exempt, name="dispatch")
class ResourceParamView(View):
    """
    Handles PATCH /api/v1/resource/{id}.

    effect classes used: http_request_parse, authorization_check,
                         database_read, database_write, audit_log_write,
                         time_read, http_response_emit
    """

    def patch(self, request, id: str, **kwargs):  # type: ignore[override]
        """effect: http_request_parse, http_response_emit"""
        # effect: http_request_parse
        payload = _parse_json_body(request)
        actor_id = _extract_actor_id(request)

        # AG_DECISION: DP-04
        try:
            result = patch_resource(
                resource_id=id,
                payload=payload,
                actor_id=actor_id,
            )
            # effect: http_response_emit
            return JsonResponse(result, status=200)

        except ObjectDoesNotExist:
            # effect: http_response_emit
            return JsonResponse(
                {"error": "Resource not found.", "resource_id": id},
                status=404,
            )

        except PermissionDenied as exc:
            # effect: http_response_emit
            return JsonResponse(
                {"error": str(exc)},
                status=403,
            )

        except ValueError as exc:
            # effect: http_response_emit
            return JsonResponse(
                {"error": str(exc)},
                status=400,
            )

        except Exception as exc:  # noqa: BLE001
            logger.exception("patch_resource_unexpected_error: %s", exc)
            # effect: http_response_emit
            return JsonResponse(
                {"error": "An unexpected error occurred."},
                status=500,
            )