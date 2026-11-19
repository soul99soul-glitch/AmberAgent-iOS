package app.amber.core.event

sealed class AppEvent {
    data class Speak(val text: String) : AppEvent()
}
