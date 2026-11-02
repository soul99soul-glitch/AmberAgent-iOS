package app.amber.cloud.config

import app.amber.cloud.runtime.CloudModelClient
import app.amber.cloud.tasks.CloudSearch
import kotlin.coroutines.AbstractCoroutineContextElement
import kotlin.coroutines.CoroutineContext

/** One Worker owns this immutable model/search generation for its entire run, including nested tools. */
class RuntimeConfigurationSnapshot(val revision: Int, val model: CloudModelClient, val search: CloudSearch) : AbstractCoroutineContextElement(Key) {
    companion object Key : CoroutineContext.Key<RuntimeConfigurationSnapshot>
}
