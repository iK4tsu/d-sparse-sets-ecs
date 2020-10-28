module ecs.component;

import std.exception : basicExceptionCtors;

version(unittest) import aurorafw.unit.assertion;


/**
 * Type which defines a valid component.
 * Use it as an **UDA** in a struct to define it as a component.
 *
 * Examples:
 * --------------------
 * @Component struct ValidComponent {}
 * --------------------
 */
public enum Component;


/**
 * Verifies a valid Component. C is a component if it's a **struct** and has the
 *     **Component UDA** attached.
 *
 * Examples:
 * --------------------
 * @Component struct ValidComponent {}
 * struct InvalidComponent {}
 *
 * assert(isComponent!ValidComponent);
 * assert(!isComponent!InvalidComponent);
 * --------------------
 *
 * Params:
 *     C = struct to validate.
 *
 * Returns: `true` if it's a component, `false` otherwise.
 */
public template isComponent(C)
	if(is(C == struct))
{
	import std.traits : hasUDA;
	enum isComponent = hasUDA!(C, Component);
}


@safe pure
@("component: isComponent")
unittest
{
	@Component struct ComponentValid {}

	struct ComponentInvalid {}
	@Component class ClassInvalid {}
	@Component int variableInvalid;

	assertTrue(isComponent!ComponentValid);
	assertFalse(isComponent!ComponentInvalid);
	assertFalse(__traits(compiles, isComponent!ClassInvalid));
	assertFalse(__traits(compiles, isComponent!variableInvalid));
}


/**
 * Returns the unique hash of the component. \
 * This is used internaly in the Registry to forge Pool ids.
 *
 * Params:
 *     C = a valid component
 *
 * Returns:
 *     An unique hash of C
 */
package template componentId(C)
	if (isComponent!C)
{
	enum componentId = typeid(C).name.hashOf();
}
