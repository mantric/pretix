#
# This file is part of pretix (Community Edition).
#
# Copyright (C) 2014-2020  Raphael Michel and contributors
# Copyright (C) 2020-today pretix GmbH and contributors
#
# This program is free software: you can redistribute it and/or modify it under the terms of the GNU Affero General
# Public License as published by the Free Software Foundation in version 3 of the License.
#
# ADDITIONAL TERMS APPLY: Pursuant to Section 7 of the GNU Affero General Public License, additional terms are
# applicable granting you additional permissions and placing additional restrictions on your usage of this software.
# Please refer to the pretix LICENSE file to obtain the full terms applicable to this work. If you did not receive
# this file, see <https://pretix.eu/about/en/license>.
#
# This program is distributed in the hope that it will be useful, but WITHOUT ANY WARRANTY; without even the implied
# warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU Affero General Public License for more
# details.
#
# You should have received a copy of the GNU Affero General Public License along with this program.  If not, see
# <https://www.gnu.org/licenses/>.
#
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
        '<h2>Premieres and live events</h2>'
        "</div>"
    )
    orga.save()
    event = Event.objects.create(
        organizer=orga,
        name="Hollywood Premiere Night",
        slug="hollywood-premiere-night",
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
    assert "advantix-logo-primary.svg" in response.rendered_content
    assert "advantix-stage-header" in response.rendered_content
    assert "advantix-demo-badge" in response.rendered_content
    assert "Demo site" in response.rendered_content


@pytest.mark.django_db
def test_advantix_event_page_loads_theme_css(advantix_env, client):
    response = client.get("/advantix/hollywood-premiere-night/")
    assert response.status_code == 200
    assert "pretixplugins/advantixtheme/advantix.css" in response.rendered_content
    assert "advantix-theme" in response.rendered_content
    assert "Premiere demo" in response.rendered_content
    assert "advantix-logo-primary.svg" in response.rendered_content
    assert "advantix-stage-header" in response.rendered_content
    assert "advantix-demo-badge" in response.rendered_content


@pytest.mark.django_db
def test_non_advantix_organizer_does_not_load_theme_css(generic_env, client):
    response = client.get("/generic/")
    assert response.status_code == 200
    assert "pretixplugins/advantixtheme/advantix.css" not in response.rendered_content
    assert "advantix-social-preview.png" not in response.rendered_content
    assert "advantix-demo-badge" not in response.rendered_content
