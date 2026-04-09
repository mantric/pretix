import json
import secrets
from datetime import timedelta

from django.conf import settings
from django.db import transaction
from django.http import JsonResponse
from django.utils import timezone
from django.utils.decorators import method_decorator
from django.views import View
from django.views.decorators.csrf import csrf_exempt

from pretix.base.models import Event, Ticket, Reservation


@method_decorator(csrf_exempt, name='dispatch')
class ReservationView(View):

    def post(self, request, *args, **kwargs):
        try:
            body = json.loads(request.body)
        except (json.JSONDecodeError, ValueError):
            return JsonResponse(
                {"error": "invalid_request", "detail": "Request body must be valid JSON."},
                status=400,
            )

        event_id = body.get("event_id")
        ticket_ids = body.get("ticket_ids") or []
        payment_mode = body.get("payment_mode")

        if not event_id or not ticket_ids or payment_mode != "pick_up_later":
            return JsonResponse(
                {
                    "error": "invalid_request",
                    "detail": "event_id, ticket_ids, and payment_mode='pick_up_later' are required.",
                },
                status=422,
            )

        try:
            event = Event.objects.get(pk=event_id)
        except Event.DoesNotExist:
            return JsonResponse(
                {"error": "event_not_found", "detail": f"Event {event_id!r} does not exist."},
                status=404,
            )

        hold_minutes = int(getattr(settings, "HOLD_PERIOD_MINUTES", 30))
        hold_expires_at = timezone.now() + timedelta(minutes=hold_minutes)

        try:
            with transaction.atomic():
                tickets = (
                    Ticket.objects.select_for_update(nowait=True)
                    .filter(pk__in=ticket_ids, event=event)
                )
                found_ids = {str(t.pk) for t in tickets}
                missing = {str(tid) for tid in ticket_ids} - found_ids
                if missing:
                    return JsonResponse(
                        {"error": "ticket_not_found", "detail": f"Tickets not found: {sorted(missing)}"},
                        status=404,
                    )

                blocked = [t for t in tickets if t.status in ("blocked", "sold")]
                if blocked:
                    return JsonResponse(
                        {
                            "error": "ticket_already_blocked",
                            "detail": f"Tickets already reserved or sold: {[str(t.pk) for t in blocked]}",
                        },
                        status=409,
                    )

                for ticket in tickets:
                    ticket.status = "blocked"
                    ticket.save(update_fields=["status"])

                reservation = Reservation.objects.create(
                    event=event,
                    secret_code=secrets.token_urlsafe(24),
                    hold_expires_at=hold_expires_at,
                    status="pending_cash_collection",
                    payment_mode=payment_mode,
                )
                reservation.tickets.set(tickets)

        except Exception:
            return JsonResponse(
                {"error": "reservation_failed", "detail": "Could not create reservation. Please try again."},
                status=500,
            )

        return JsonResponse(
            {
                "reservation_id": str(reservation.pk),
                "secret_code": reservation.secret_code,
                "hold_expires_at": hold_expires_at.isoformat(),
                "status": reservation.status,
            },
            status=201,
        )
