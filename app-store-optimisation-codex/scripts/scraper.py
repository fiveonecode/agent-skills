"""
Prompt templates for browsing App Store and Google Play pages.

Use these prompts with Codex browsing (web.run) to extract structured data
when official APIs do not provide the fields you need.
"""

from typing import Dict


class WebFetchPrompts:
    """Prompt templates for browsing app store pages."""

    @staticmethod
    def app_store_search(keyword: str) -> Dict[str, str]:
        """
        Generate a browsing prompt for App Store search results.

        Args:
            keyword: Search keyword

        Returns:
            Dictionary with URL and prompt for browsing
        """
        url = f"https://apps.apple.com/us/search?term={keyword.replace(' ', '+')}"
        prompt = f"""
        Extract information about the top 10 apps shown in search results for "{keyword}".

        For each app, provide:
        1. App name
        2. Developer name
        3. Category
        4. Icon URL (if visible)
        5. App Store URL/link
        6. Brief tagline or description snippet
        7. Rating (if visible)

        Format as JSON array with these fields.
        """

        return {
            "url": url,
            "prompt": prompt
        }

    @staticmethod
    def app_store_app_page(app_url: str) -> Dict[str, str]:
        """
        Generate a browsing prompt for an App Store app page.

        Args:
            app_url: Full URL to app page

        Returns:
            Dictionary with URL and prompt for browsing
        """
        prompt = """
        Extract the following information from this App Store app page:

        **Metadata:**
        1. App title (exact text)
        2. Subtitle (if present)
        3. Developer name
        4. Category
        5. Full description text
        6. "What's New" section (latest update)
        7. App Store URL

        **Ratings & Reviews:**
        8. Average rating (e.g., 4.7)
        9. Total number of ratings
        10. Recent reviews (first 3-5 visible reviews with rating and text)

        **Visual Assets:**
        11. Number of screenshots shown
        12. Does it have an app preview video? (yes/no)

        **Additional Info:**
        13. Age rating
        14. Languages supported (if listed)
        15. File size
        16. Price or "Free"

        Format as structured JSON with these fields.
        """

        return {
            "url": app_url,
            "prompt": prompt
        }

    @staticmethod
    def play_store_search(keyword: str) -> Dict[str, str]:
        """
        Generate a browsing prompt for Google Play Store search results.

        Args:
            keyword: Search keyword

        Returns:
            Dictionary with URL and prompt for browsing
        """
        url = f"https://play.google.com/store/search?q={keyword.replace(' ', '+')}&c=apps"
        prompt = f"""
        Extract information about the top 10 apps shown in search results for "{keyword}".

        For each app, provide:
        1. App name
        2. Developer name
        3. Category
        4. Play Store URL/package name
        5. Brief description snippet
        6. Rating (if visible)
        7. Number of downloads range (e.g., "1M+")

        Format as JSON array with these fields.
        """

        return {
            "url": url,
            "prompt": prompt
        }

    @staticmethod
    def play_store_app_page(app_url_or_package: str) -> Dict[str, str]:
        """
        Generate a browsing prompt for a Google Play Store app page.

        Args:
            app_url_or_package: Full URL or package name (e.g., com.todoist)

        Returns:
            Dictionary with URL and prompt for browsing
        """
        if app_url_or_package.startswith("http"):
            url = app_url_or_package
        else:
            url = f"https://play.google.com/store/apps/details?id={app_url_or_package}"

        prompt = """
        Extract the following information from this Google Play Store app page:

        **Metadata:**
        1. App title (exact text)
        2. Developer name
        3. Category
        4. Short description (first paragraph/tagline)
        5. Full description text
        6. "What's new" section (latest update notes)

        **Ratings & Reviews:**
        7. Average rating (e.g., 4.5)
        8. Total number of reviews
        9. Rating distribution (5-star, 4-star, etc. percentages if visible)
        10. Recent reviews (first 3-5 visible reviews with rating and text)

        **Visual Assets:**
        11. Number of screenshots shown
        12. Does it have a promo video? (yes/no)
        13. Feature graphic present? (yes/no)

        **Additional Info:**
        14. Downloads range (e.g., "10M+")
        15. Content rating (e.g., "Everyone", "Teen")
        16. Size (e.g., "50MB")
        17. Price or "Free"
        18. In-app purchases range (if listed)

        Format as structured JSON with these fields.
        """

        return {
            "url": url,
            "prompt": prompt
        }
