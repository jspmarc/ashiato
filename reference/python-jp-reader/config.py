from pathlib import Path

from pydantic import model_validator
from pydantic_settings import BaseSettings, SettingsConfigDict

_ENV = SettingsConfigDict(env_file=".env", env_file_encoding="utf-8", extra="ignore")


def _config(prefix: str) -> SettingsConfigDict:
    """Settings config for a section, reading `.env` with the given prefix."""
    return SettingsConfigDict(
        env_prefix=prefix,
        env_file=".env",
        env_file_encoding="utf-8",
        extra="ignore",
    )


class AppSettings(BaseSettings):
    model_config = _config("APP_")

    debug: bool = False
    temp_dir: Path = Path("/tmp/ashiato")
    max_upload_mb: int = 200
    # One shared write password for every tool, until account auth replaces
    # it. Empty means all writes are refused.
    password: str = ""
    database_url: str | None = None
    broker_url: str | None = None


class TranslationSettings(BaseSettings):
    model_config = _config("TRANSLATION_")

    fallback: str = "mymemory"  # provider used when Google refuses; "" disables


class JpReaderSettings(BaseSettings):
    model_config = _config("JR_")

    target_lang: str = "en"
    max_images: int = 50  # cap on stored images; oldest are evicted
    ttl_days: int = 7
    max_dim: int = 2000  # longest edge of the stored (and OCR'd) image


class Settings(BaseSettings):
    model_config = _ENV

    app: AppSettings = AppSettings()
    translation: TranslationSettings = TranslationSettings()
    jp_reader: JpReaderSettings = JpReaderSettings()

    @model_validator(mode="after")
    def check_required_on_start(self) -> "Settings":
        # Future: add startup-required checks here, e.g.:
        # if not self.app.some_field:
        #     raise ValueError("APP_SOME_FIELD is required")
        return self


settings = Settings()
