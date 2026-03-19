from datetime import timedelta

import pytest
from django.utils.timezone import now

from pretix.base.models import Event, Organizer


@pytest.fixture
def advantix_env():
    orga = Organizer.objects.create(name="Advantix", slug="advantix")
    orga.settings.organizer_homepage_text = (
        '<div class="advantix-hero">'
        '<p class="advantix-kicker">Demo</p>'
        '<h2>Movie nights and live events</h2>'
        "</div>"
    )
    orga.save()
    event = Event.objects.create(
        organizer=orga,
        name="Mumbai Movie Night",
        slug="mumbai-movie-night",
        date_from=now() + timedelta(days=7),
        live=True,
        is_public=True,
    )
    event.settings.frontpage_text = (
        '<div class="advantix-hero advantix-hero-compact">'
        '<p class="advantix-kicker">Premiere demo</p>'
        '<h2>Friday night screening</h2>'
        "</div>"
    )
    event.save()
    return orga, event


@pytest.fixture
def generic_env():
    orga = Organizer.objects.create(name="Generic Org", slug="generic")
    Event.objects.create(
        organizer=orga,
        name="Generic Event",
        slug="generic-event",
        date_from=now() + timedelta(days=7),
        live=True,
        is_public=True,
    )
    return orga


@pytest.mark.django_db
def test_advantix_organizer_page_loads_theme_css_and_social_preview(advantix_env, client):
    response = client.get("/advantix/")
    assert response.status_code == 200
    assert "pretixplugins/advantixtheme/advantix.css" in response.rendered_content
    assert "advantix-theme" in response.rendered_content
    assert "advantix-social-preview.png" in response.rendered_content


@pytest.mark.django_db
def test_advantix_event_page_loads_theme_css(advantix_env, client):
    response = client.get("/advantix/mumbai-movie-night/")
    assert response.status_code == 200
    assert "pretixplugins/advantixtheme/advantix.css" in response.rendered_content
    assert "advantix-theme" in response.rendered_content
    assert "Premiere demo" in response.rendered_content


@pytest.mark.django_db
def test_non_advantix_organizer_does_not_load_theme_css(generic_env, client):
    response = client.get("/generic/")
    assert response.status_code == 200
    assert "pretixplugins/advantixtheme/advantix.css" not in response.rendered_content
    assert "advantix-social-preview.png" not in response.rendered_content
