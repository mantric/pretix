from django.urls import path

from pretix.api.views.reservations import ReservationView

urlpatterns = [
    path('reservations/', ReservationView.as_view(), name='reservations'),
]
