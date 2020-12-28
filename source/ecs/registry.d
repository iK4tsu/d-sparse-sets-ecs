module ecs.registry;

import std.exception : basicExceptionCtors;
import ecs.entity;
import ecs.sparseset : SparseSet;

version(unittest) import aurorafw.unit.assertion;


/**
 * Basic exception for PoolData
 */
public class PoolDataException : Exception
{
	mixin basicExceptionCtors;
}


///
public final class PoolDoesNotExistException : PoolDataException
{
	mixin basicExceptionCtors;
}


/**
 * BasicRegistry manages all entities. It's responsible for creating, discarding,
 *     generate unique references and make safety checks all around entities and
 *     component pools.
 *
 * Params:
 *     T = valid EntityType.
 *     idBitAmount = bit amount for entity ids
 */
@safe pure
public final class BasicRegistry(T, T idBitAmount)
	if(isEntityType!T && __traits(compiles, SparseSet!(T, idBitAmount)))
{
	import std.conv : to;
	import std.exception : enforce;
	import std.meta : allSatisfy;
	import std.traits : Fields;
	import ecs.component : isComponent, componentId;
	import ecs.pool : Pool;

	mixin genEntityBitMasks!(T, idBitAmount);

public:
	// TODO: containsAny
	// TODO: modifyOrAdd
	// TODO: getOrNull (must return null ptr with failure)
	// TODO: iterators
	// TODO: entitiesWith (idealy returns an iterator)


	/**
	 * Creates a new entity either by spawning a new id or reusing one in the
	 *     queue.
	 *
	 * Returns: a new entity reference with a reused id if the queue isn't
	 *     empty or with a new spawned id otherwise.
	 *
	 * See_Also: $(LREF spawn), $(LREF revive), $(LREF discard)
	 */
	@safe pure
	T create()
	{
		return queue == entityNull ? spawn() : revive();
	}


	/**
	 * Creates entities either by spawning a new id or reusing one in the
	 *     queue.
	 *
	 * Params: n = amount to create.
	 *
	 * Returns: a new entity reference with a reused id if the queue isn't
	 *     empty or with a new spawned id otherwise.
	 *
	 * See_Also: $(LREF spawn), $(LREF revive), $(LREF discard)
	 */
	@safe pure
	T[] create(in T n)
		in (n > 0)
	{
		import std.algorithm : map;
		import std.array : array;
		import std.range : iota;

		return n.iota.map!(e => create()).array;
	}


	/**
	 * Destroy a valid entity and update the batch. \
	 * When an entity is discarded it's batch is updated and stored. This will be
	 *     used when the destroyed id is reused.
	 *
	 * Params: entity = entity to be destroyed.
	 *
	 * See_Also: $(LREF create), $(LREF spawn), $(LREF revive), $(LREF idOf),
	 *     $(LREF updateBatch) to understand how it updates
	 */
	@safe pure
	void discard(const inout(T) entity)
	{
		enforce!InvalidEntityException(isValid(entity), "Cannot discard entity with invalid id!");
		removeAll(entity);
		const id = idOf(entity);
		const batch = updateBatch(entity);
		entities[id] = cast(T)(queue | (batch << entityShift));
		queue = id;
	}


	/**
	 * Get the batch of any valid or invalid entity's reference.
	 *
	 * Params: entity = reference from which the batch is going to be extracted.
	 *
	 * Returns: the entity's batch.
	 *
	 * See_Also: $(LREF currentBatchOf), $(LREF idOf)
	 */
	@safe pure
	inout(T) batchOf(const inout(T) entity) const inout
	{
		return entity >> entityShift;
	}


	/**
	 * Get the current batch of an entity reference id which has spawned. \
	 * If the extracted id of the given entity reference hasn't been spawned yet,
	 *     meaning the id hasn't been created, an EntityException will be thrown.
	 *
	 * Params: entity = refence once spawned from which the id is going to be
	 *     extracted.
	 *
	 * Throws: $(LREF EntityException) if the reference id has been created.
	 *
	 * Returns: the batch of the current id extracted from the entity's
	 *     reference.
	 *
	 * See_Also: $(LREF batchOf), $(LREF idOf)
	 */
	@safe pure
	inout(T) currentBatchOf(const inout(T) entity) const inout
	{
		enforce!InvalidEntityException(hasSpawned(entity), "Cannot extract the batch from an invalid entity!");
		return entities[idOf(entity)] >> entityShift;
	}


	/**
	 * Get the id of any valid or invalid entity's reference.
	 *
	 * Params: entity = reference from which the id is going to be extracted.
	 *
	 * Returns: the entity's id
	 *
	 * See_Also: $(LREF batchOf), $(LREF currentBatchOf)
	 */
	@safe pure
	inout(T) idOf(const inout(T) entity) const inout
	{
		return entity & entityMask;
	}


	/**
	 * Check if an entity's reference is valid. \
	 * A valid reference is defined by:
	 *
	 * * it's id must have been created byt this registry at some point.
	 * * the entity needs to be alive.
	 *
	 * Params: entity = reference to validate.
	 *
	 * Returns: `true` if valid, `false` otherwise.
	 *
	 * See_Also: $(LREF hasSpawned)
	 */
	@safe pure
	bool isValid(const inout(T) entity) const inout
	{
		return hasSpawned(entity) && entities[idOf(entity)] == entity;
	}


	/**
	 * Check if an entity's reference id has been created by this registry at
	 *     some point.
	 *
	 * Params: entity = reference from which the extracted id will be evaluated.
	 *
	 * Returns: `true` if the extracted id has been created, `false` otherwise.
	 *
	 * See_Also: $(LREF isValid)
	 */
	@safe pure
	bool hasSpawned(const inout(T) entity) const inout
	{
		return idOf(entity) < entities.length;
	}


	/**
	 * Add a component. \
	 * \
	 * Components cannot be added to an enity which already contains a component
	 *     of the same type.
	 *
	 * Params: C = valid component.
	 */
	template add(C)
		if (isComponent!C)
	{
		import std.algorithm : each;

		/**
		 * Add a component to an entity. \
		 * By default the component is initialized to it's default values.
		 *
		 * Params:
		 *     entity = a valid entity.
		 *     component = a valid component to add.
		 */
		void add(in T entity, in C component = C.init)
		{
			enforce!InvalidEntityException(isValid(entity), "Cannot add a component to an invalid entity");
			immutable cid = componentId!C;
			auto ptr = cid in pools;

			if (ptr is null)
			{
				pools[cid] = PoolData(
					new Pool!(T, idBitAmount, C)(),
					delegate void(SparseSet!(T, idBitAmount) pool, in T entity) @safe pure {
						(cast(Pool!(T, idBitAmount, C))(pool)).remove(entity);
					}
				);
			}
			else
			{
				enforce!EntityInPoolException(!(*ptr).pool.contains(entity), "Cannot add a component to an entity already in the Pool!");
			}

			Pool!(T, idBitAmount, C) pool = cast(Pool!(T, idBitAmount, C))(pools[cid].pool);
			pool.add(entity, component);
		}


		/**
		 * Add a component to entities. \
		 * By default the component is initialized to it's default values.
		 *
		 * Params:
		 *     entities = valid entities.
		 *     component = a valid component to add.
		 */
		void add(in T[] entities, in C component = C.init)
		{
			entities.each!(e => add(e, component));
		}


		/**
		 * Add a component to an entity. \
		 *
		 * Params:
		 *     entity = a valid entity.
		 *     args = all component fields.
		 *
		 * Examples:
		 * --------------------
		 * @Component struct Foo { int a; }
		 * add!Foo(e, 3); // adds Foo(3) to entity e
		 * --------------------
		 */
		void add(in T entity, Fields!C args)
		{
			add(entity, C(args));
		}


		/**
		 * Add a component to entities. \
		 *
		 * Params:
		 *     entities = valid entities.
		 *     args = all component fields.
		 *
		 * Examples:
		 * --------------------
		 * @Component struct Foo { int a; }
		 * add!Foo(e, 3); // adds Foo(3) to entities e
		 * --------------------
		 */
		void add(in T[] entities, Fields!C args)
		{
			entities.each!(e => add(e, C(args)));
		}
	}


	/**
	 * Add components. \
	 * \
	 * Components cannot be added to an enity which already contains a component
	 *     of the same type.
	 *
	 * Params: RangeC = a valid component's range.
	 */
	template add(RangeC ...)
		if (RangeC.length > 1)
	{
		import std.algorithm : each;

		/**
		 * Add components to an entity. \
		 * Components will be initialized to `.init`.
		 *
		 * Params: entity = a valid entity.
		 */
		void add(in T entity)
		{
			foreach (C; RangeC) add!C(entity);
		}


		/**
		 * Add components to an entity.
		 *
		 * Params:
		 *     entity = a valid entity.
		 *     components = valid components to add.
		 */
		void add(in T entity, in RangeC components)
		{
			foreach (ref component; components) add(entity, component);
		}


		/**
		 * Add components to entities. \
		 * Components will be initialized to `.init`
		 *
		 * Params: entities = valid entities.
		 */
		void add(in T[] entities)
		{
			entities.each!(e => add!(RangeC)(e));
		}


		/**
		 * Add components to entities.
		 *
		 * Params:
		 *     entities = valid entities.
		 *     components = valid components to add.
		 */
		void add(in T[] entities, in RangeC components)
		{
			entities.each!(e => add(e, components));
		}
	}


	/**
	 * Get a component from an entity.
	 *
	 * Params:
	 *     C = valid component to get.
	 *     entity = valid entity to search.
	 *
	 * Returns: a pointer to the respective component.
	 */
	C* get(C)(in T entity)
		if (isComponent!C)
	{
		enforce!InvalidEntityException(isValid(entity), "Cannot get a component from an invalid entity!");
		enforce!PoolDoesNotExistException(componentId!C in pools, "Cannot get a component from a non existent Pool!");
		enforce!EntityNotInPoolException(pools[componentId!C].pool.contains(entity), "Cannot get a component from an entity which does not contain it!");

		return (cast(Pool!(T, idBitAmount, C))(pools[componentId!C].pool)).get(entity);
	}


	/**
	 * Get components from an entity
	 *
	 * Params:
	 *     RangeC = valid component's range.
	 *     entity = valid entity to search.
	 *
	 * Returns: a tuple with pointers to the respective components.
	 */
	auto get(RangeC ...)(in T entity)
		if (RangeC.length > 1)
	{
		import std.typecons : tuple;
		return tuple(get!(RangeC[0])(entity)) ~ get!(RangeC[1 .. $])(entity);
	}


	/**
	 * Contains a component. \
	 *
	 * Params: C = valid component to check.
	 */
	template contains(C)
		if (isComponent!C)
	{
		import std.algorithm : each;
		import std.typecons : No, Yes;

		/**
		 * Checks if an entity, valid or not, contains a component. \
		 * \
		 * If the entity isn't valid or the component pool doesn't exist or the
		 *     entity does not contain it, it returns `false`!
		 *
		 * Params: entity = entity to search.
		 *
		 * Returns: `true` if the entity contains the component, `false` otherwise.
		 */
		auto contains(in T entity)
		{
			return isValid(entity)
				&& componentId!C in pools
				&& pools[componentId!C].pool.contains(entity);
		}


		/**
		 * Checks if an entity, valid or not, contains a component. \
		 * \
		 * If the entity isn't valid or the component pool doesn't exist or the
		 *     entity does not contain it, it returns `false`!
		 *
		 * Params:
		 *     component = valid component to check.
		 *     entity = entity to search.
		 *
		 * Returns: `true` if the entity contains the component, `false` otherwise.
		 */
		auto contains(in T entity, in C component)
		{
			return isValid(entity)
				&& componentId!C in pools
				&& (cast(Pool!(T, idBitAmount, C))(pools[componentId!C].pool)).contains(entity, component);
		}


		/**
		 * Checks if all entities, valid or not, contain a component. \
		 * \
		 * If the entity isn't valid or the component pool doesn't exist or the
		 *     entity does not contain it, it returns `false`!
		 *
		 * Params: entities = entities to search.
		 *
		 * Returns: `true` if all entities contain the component, `false` otherwise.
		 */
		auto contains(in T[] entities)
		{
			return entities.each!(e => contains!C(e) ? Yes.each : No.each) == Yes.each;
		}


		/**
		 * Checks if all entities, valid or not, contain a component. \
		 * \
		 * If the entity isn't valid or the component pool doesn't exist or the
		 *     entity does not contain it, it returns `false`!
		 *
		 * Params:
		 *     component = valid component to check.
		 *     entities = entities to search.
		 *
		 * Returns: `true` if all entities contain the component, `false` otherwise.
		 */
		auto contains(in T[] entities, in C component)
		{
			return entities.each!(e => contains!C(e, component) ? Yes.each : No.each) == Yes.each;
		}
	}


	/**
	 * Contains components. \
	 *
	 * Params: RangeC = valid components to check.
	 */
	template contains(RangeC ...)
		if (RangeC.length > 1)
	{
		import std.algorithm : each;
		import std.typecons : No, Yes;

		/**
		 * Checks if an entity, valid or not, contains all components. \
		 * \
		 * If the entity isn't valid or a component pool doesn't exist or the
		 *     entity does not contain it, it returns `false`!
		 *
		 * Params: entity = entity to search.
		 *
		 * Returns: `true` if all entities contain all components, `false` otherwise.
		 */
		auto contains(in T entity)
		{
			foreach (C; RangeC)
			{
				if (!contains!C(entity))
					return false;
			}
			return true;
		}


		/**
		 * Checks if an entity, valid or not, contains all components. \
		 * \
		 * If the entity isn't valid or a component pool doesn't exist or the
		 *     entity does not contain it, it returns `false`!
		 *
		 * Params:
		 *     components = valid components to check.
		 *     entity = entity to search.
		 *
		 * Returns: `true` if the entity contains all components, `false` otherwise.
		 */
		auto contains(in T entity, in RangeC components)
		{
			foreach (ref component; components)
			{
				if (!contains(entity, component))
					return false;
			}
			return true;
		}


		/**
		 * Checks if all entities, valid or not, contain all components. \
		 * \
		 * If any entity isn't valid or a component pool doesn't exist or the
		 *     entity does not contain it, it returns `false`!
		 *
		 * Params: entities = entities to search.
		 *
		 * Returns: `true` if all entities contain all components, `false` otherwise.
		 */
		auto contains(in T[] entities)
		{
			return entities.each!(e => contains!(RangeC)(e) ? Yes.each : No.each) == Yes.each;
		}


		/**
		 * Checks if all entities, valid or not, contain all components. \
		 * \
		 * If any entity isn't valid or a component pool doesn't exist or the
		 *     entity does not contain it, it returns `false`!
		 *
		 * Params:
		 *     components = valid components to check.
		 *     entities = entities to search.
		 *
		 * Returns: `true` if all entities contain all components, `false` otherwise.
		 */
		auto contains(in T[] entities, in RangeC components)
		{
			return entities.each!(e => contains!(RangeC)(e, components) ? Yes.each : No.each) == Yes.each;
		}
	}


	template containsAny(RangeC ...)
		if (RangeC.length > 1)
	{
		import std.algorithm : each;
		import std.typecons : No, Yes;


		/**
		 * Checks if an entity, valid or not, contains any component. \
		 * \
		 * If the entity isn't valid or a component pool doesn't exist or the
		 *     entity does not contain it, it returns `false`!
		 *
		 * Params:
		 *     components = valid components to check.
		 *     entity = entity to search.
		 *
		 * Returns: `true` if the entity contains any component, `false` otherwise.
		 */
		auto containsAny(in T entity)
		{
			foreach (C; RangeC)
			{
				if (contains!C(entity))
					return true;
			}
			return false;
		}


		/**
		 * Checks if an entity, valid or not, contains any component. \
		 * \
		 * If the entity isn't valid or a component pool doesn't exist or the
		 *     entity does not contain it, it returns `false`!
		 *
		 * Params:
		 *     components = valid components to check.
		 *     entity = entity to search.
		 *
		 * Returns: `true` if the entity contains any component, `false` otherwise.
		 */
		auto containsAny(in T entity, in RangeC components)
		{
			foreach (ref component; components)
			{
				if (contains(entity, component))
					return true;
			}
			return false;
		}


		/**
		 * Checks if all entities, valid or not, contain any component. \
		 * \
		 * If any entity isn't valid or a component pool doesn't exist or the
		 *     entity does not contain it, it returns `false`!
		 *
		 * Params: entities = entities to search.
		 *
		 * Returns: `true` if all entities contain any component, `false` otherwise.
		 */
		auto containsAny(in T[] entities)
		{
			return entities.each!(e => containsAny!(RangeC)(e) ? Yes.each : No.each) == Yes.each;
		}


		/**
		 * Checks if all entities, valid or not, contain any component. \
		 * \
		 * If any entity isn't valid or a component pool doesn't exist or the
		 *     entity does not contain it, it returns `false`!
		 *
		 * Params:
		 *     components = valid components to check.
		 *     entities = entities to search.
		 *
		 * Returns: `true` if all entities contain any component, `false` otherwise.
		 */
		auto containsAny(in T[] entities, in RangeC components)
		{
			return entities.each!(e => containsAny!(RangeC)(e, components) ? Yes.each : No.each) == Yes.each;
		}
	}


	/**
	 * Remove a component. \
	 * A component cannot be removed if an entity isn't valid or the component
	 *     hasn't been created yet or the entity doesn't contain the component.
	 *
	 * Params: C = valid component to remove.
	 *
	 * Throws: **InvalidEntityException**, **PoolDoesNotExistException** and
	 *     **EntityNotInPoolException**
	 */
	template remove(C)
		if (isComponent!C)
	{
		/**
		 * Remove a component from an entity.
		 *
		 * Params: entity = a valid entity.
		 *
		 * Throws: **InvalidEntityException**, **PoolDoesNotExistException** and
		 *     **EntityNotInPoolException**
		 */
		void remove(in T entity)
		{
			// TODO: just ignore this an do nothing?
			enforce!InvalidEntityException(isValid(entity), "Cannot remove a component from an invalid entity!");
			enforce!PoolDoesNotExistException(componentId!C in pools, "Cannot remove a component from a non existent Pool!");
			enforce!EntityNotInPoolException(pools[componentId!C].pool.contains(entity), "Cannot remove a component from an entity which does not contain it!");

			pools[componentId!C].remove(pools[componentId!C].pool, entity);
		}

		/**
		 * Remove a component from entities.
		 *
		 * Params: entity = a valid entity.
		 */
		void remove(in T[] entities)
		{
			import std.algorithm : each;
			entities.each!(e => remove!C(e));
		}
	}


	/**
	 * Remove components. \
	 * A component cannot be removed if an entity isn't valid or the component
	 *     hasn't been created yet or the entity doesn't contain the component.
	 *
	 * Params: RangeC = valid components to remove.
	 *
	 * Throws: **InvalidEntityException**, **PoolDoesNotExistException** and
	 *     **EntityNotInPoolException**
	 */
	template remove(RangeC ...)
		if (RangeC.length > 1)
	{
		/**
		 * Remove components from an entity.
		 *
		 * Params: entity = a valid entity.
		 */
		void remove(in T entity)
		{
			foreach (C; RangeC) remove!C(entity);
		}


		/**
		 * Remove components from entities.
		 *
		 * Params: entities = valid entities.
		 */
		void remove(in T[] entities)
		{
			import std.algorithm : each;
			entities.each!(e => remove!(RangeC)(e));
		}
	}


	/**
	 * Remove every component from an entity.
	 *
	 * Params: entity = valid entity to remove all components from.
	 */
	@safe pure
	void removeAll(in T entity)
	{
		// TODO: delete component pool with 0 entities?
		enforce!InvalidEntityException(isValid(entity), "Cannot remove components from an invalid entity!");
		foreach (ref PoolData poolData; pools)
		{
			if (poolData.pool.contains(entity))
			{
				poolData.remove(poolData.pool, entity);
			}
		}
	}


	/**
	 * Remove every component from multiple entities.
	 *
	 * Params: entities = valid entities to remove all components from.
	 */
	@safe pure
	void removeAll(in T[] entities)
	{
		import std.algorithm : each;
		entities.each!(e => removeAll(e));
	}


	/**
	 * Edit the data of a component.
	 *
	 * Params: C = valid component.
	 */
	template modify(C)
		if (isComponent!C)
	{
		/**
		 * Params:
		 *     entity = valid entity.
		 *     component = valid component.
		 *
		 * Examples:
		 * --------------------
		 * @component struct Position { float x, y; }
		 * registry.modify(e0, Position(2, 3)); // first is x then y
		 * --------------------
		 */
		void modify(in T entity, scope auto ref C component)
		{
			enforce!InvalidEntityException(isValid(entity), "Cannot modify a component from an invalid entity!");
			enforce!PoolDoesNotExistException(componentId!C in pools, "Cannot modify a component from a non existent Pool!");
			enforce!EntityNotInPoolException(pools[componentId!C].pool.contains(entity), "Cannot modify a component from an entity which does not contain it!");

			(cast(Pool!(T, idBitAmount, C))(pools[componentId!C].pool)).modify(entity, component);
		}


		/**
		 * The data must be inserted by the same order which is declared in the
		 *     component. \
		 * \
		 * The program won't compile when trying to pass a variable which doesn't
		 *     exist in the component or if it exists it's not in the correct spot.
		 *
		 * Params:
		 *     entity = valid entity.
		 *     args = all component's fields.
		 *
		 * Examples:
		 * --------------------
		 * @component struct Position { float x, y; }
		 * registry.modify!Position(e0, 2, 3); // first is x then y
		 * --------------------
		 *
		 * --------------------
		 * @component struct Foo { string x; float y; }
		 * assert( __traits(compiles, registry.modify!Foo(e0, "nice!", 3));
		 * assert(!__traits(compiles, registry.modify!Foo(e0, 2, 3));
		 * assert(!__traits(compiles, registry.modify!Foo(e0, 2, "not valid"));
		 * --------------------
		 */
		void modify(in T entity, Fields!C args)
		{
			modify(entity, C(args));
		}
	}


	template modify(RangeC ...)
		if (RangeC.length > 1)
	{
		void modify(in T entity, scope RangeC components)
		{
			foreach (ref component; components) modify(entity, component);
		}

		void modify(in T[] entities, scope RangeC components)
		{
			import std.algorithm : each;
			entities.each!(e => modify(e, components));
		}
	}


private:
	/**
	 * Generate a new entity's id. \
	 * Every time a new id is spawned it's batch is set to 0.
	 *
	 * Returns: an entity with a new id.
	 *
	 * See_Also: $(LREF revive), $(LREF create), $(LREF discard)
	 */
	@safe pure
	T spawn()
	{
		import std.range : back;

		enforce!MaximumEntitiesReachedException(entities.length < entityMask, "Maximum entities reached!");
		entities ~= entities.length.to!T;

		return entities.back;
	}


	/**
	 * Generate a new entity with a reused id. \
	 * Whenever the queue isn't empty it's id is reused.
	 *
	 * Returns: an entity with a reused id.
	 *
	 * See_Also: $(LREF spawn), $(LREF create), $(LREF discard)
	 */
	@safe pure
	T revive()
		in(queue != entityNull, "Must have dead entities to revive!")
	{
		immutable batch = batchOf(entities[queue]);
		immutable id = queue;
		queue = idOf(entities[id]);
		entities[id] = (id | (batch << entityShift)).to!T;

		return entities[id];
	}


	/**
	 * Increments the reference's batch of a valid entity by 1. \
	 * If the batch is at it's max value then it's reseted to 0.
	 *
	 * Params: entity = reference which batch is going to be updated.
	 *
	 * Returns: the new updated batch's value
	 *
	 * See_Also: $(LREF isValid), $(LREF batchOf), $(LREF currentBatchOf)
	 */
	@safe pure
	inout(T) updateBatch(const inout(T) entity) const inout
		in(isValid(entity))
	{
		immutable T batch = batchOf(entity);

		return batch == batchMask ? 0 : (batch + 1).to!T;
	}


	/**
	 * Pool data storage struct. PoolData stores a pool of a component as well
	 *     as a delegate to access the remove function of the same pool. \
	 * \
	 * Because we need to store pools in arrays we can't join pools of diferent
	 *     components in one array. The same applies when using the SparseSet
	 *     parent class. We can jumble together all the diferent components
	 *     in one array, but what happens when we want to access them? How can
	 *     we distiguish a Pool of ComponentA from the Pool of ComponentB
	 *     without iterating all pools?
	 * \
	 * PoolData fixes this issue. We create an associative array of this data
	 *     structure and to access each of them we use an uniquely generated
	 *     id of a valid Component. Then we can access the parent class directly
	 *     and when we want to access the Pool class we cast it easily using
	 *     the same component id as guidance. \
	 * \
	 * The remove function serves a different purpose. What happens when we
	 *     delete an entity? How do can we delete all components associated with
	 *     that entity? The remove delegate fixes this. When constructing the
	 *     PoolData we set the scope to cast the SparseSet to the correct Pool
	 *     and then we just call the Pool's remove function.
	 */
	@safe pure
	struct PoolData
	{
		SparseSet!(T, idBitAmount) pool;
		@safe pure void delegate(SparseSet!(T, idBitAmount), in T) remove;
	}

	T[] entities;
	PoolData[size_t] pools;
	T queue = entityNull;
}


/**
 * A registry with variable type of ***ulong***. \
 * This comes with:
 * + id: ***32 bits*** (max at `4_294_967_295`)
 * + batch: ***32 bits*** (resets at `4_294_967_296`)
 *
 * Examples:
 * --------------------
 * auto registry = Registry64();
 * --------------------
 */
alias Registry64 = BasicRegistry!(ulong, 32);

/**
 * A registry with variable type of ***uint***. \
 * This comes with:
 * + id: ***16 bits*** (max at `65_534`)
 * + batch: ***16 bits*** (resets at `65_536`)
 *
 * Examples:
 * --------------------
 * auto registry = Registry32();
 * --------------------
 */
alias Registry32 = BasicRegistry!(uint, 16);

/**
 * A registry with variable type of ***ushort***. \
 * This comes with:
 * + id: ***8 bits*** (max at `254`)
 * + batch: ***8 bits*** (resets at `256`)
 *
 * Examples:
 * --------------------
 * auto registry = Registry16();
 * --------------------
 */
alias Registry16 = BasicRegistry!(ushort, 8);

/**
 * A registry with variable type of ***ubyte***. \
 * This comes with:
 * + id: ***4 bits*** (max at `14`)
 * + batch: ***4 bits*** (resets at `16`)
 *
 * Examples:
 * --------------------
 * auto registry = Registry8();
 * --------------------
 */
alias Registry8 = BasicRegistry!(ubyte, 4);

/**
 * The default registry with variable type of ***uint***. \
 * This comes with:
 * + id: ***20 bits*** (max at `1_048_574`)
 * + batch: ***12 bits*** (resets at `4_096`)
 *
 * Examples:
 * --------------------
 * auto registry = Registry();
 * --------------------
 */
alias Registry = BasicRegistry!(uint, 20);


version(unittest)
{
	import ecs.component : Component;
	private @Component struct Position { float x, y; }
	private @Component struct Velocity { float dx, dy; }
	private @Component struct Colision {}
	private struct NotComponent {}
}


@safe pure
@("registry: add")
unittest
{
	auto registry = new Registry8();
	auto e0 = registry.create();
	auto e1 = registry.create();
	immutable ubyte invalid = 15;

	auto exceptionIE = expectThrows!InvalidEntityException(registry.add(invalid, Position(2, 4)));
	assertEquals("Cannot add a component to an invalid entity", exceptionIE.msg);

	registry.add(e0, Position(2, 4));

	auto exceptionEIP = expectThrows!EntityInPoolException(registry.add(e0, Position(2, 4)));
	assertEquals("Cannot add a component to an entity already in the Pool!", exceptionEIP.msg);

	registry.add!Colision(e1);

	assertTrue(registry.contains!Position(e0));
	assertFalse(registry.contains!Velocity(e0));

	assertTrue(registry.contains!Colision(e1));
	assertFalse(registry.contains!Position(e1));

	assertFalse(__traits(compiles, registry.add(e0, NotComponent())));

	registry.add!Velocity([e0, e1]);

	assertTrue(registry.contains!Velocity(e0));
	assertTrue(registry.contains!Velocity(e1));

	auto entities = registry.create(2);

	registry.add!(Position, Colision)(entities);

	assertTrue(registry.contains!(Position, Colision)(entities[0]));

	entities = registry.create(2);

	registry.add(entities, Position.init, Velocity(2, 3), Colision.init);

	assertTrue(registry.contains!(Position, Velocity, Colision)(entities[0]));
}


@safe pure
@("registry: add syntax sugar")
unittest
{
	auto registry = new Registry8();
	auto e0 = registry.create();
	auto e1 = registry.create();

	registry.add!Position(e0, 2, 4);

	assertTrue(registry.contains!Position(e0));

	registry.add!Velocity([e0, e1], 6, 24);

	assertTrue(registry.contains!Velocity(e0));
	assertTrue(registry.contains!Velocity(e1));
	assertTrue(Velocity(6, 24) == *registry.get!Velocity(e0));
}


@safe pure
@("registry: batchOf")
unittest
{
	auto registry = new Registry();
	auto e0 = registry.create();
	assertEquals(0, registry.batchOf(e0));

	registry.discard(e0);
	assertEquals(0, registry.batchOf(e0));

	auto e1 = registry.create();
	assertEquals(1, registry.batchOf(e1));
	assertEquals(0, registry.batchOf(e0));
}


@safe pure
@("registry: contains")
unittest
{
	import ecs.component : componentId;
	auto registry = new Registry();
	auto e0 = registry.create();
	auto e1 = registry.create();

	assertFalse(registry.contains!Position(e0));

	registry.add!Position(e0, 1, 1);
	assertFalse(registry.contains!(Position, Velocity)(e0));

	registry.add!Velocity(e0, 3, 4);
	assertTrue(registry.contains!(Position, Velocity)(e0));

	registry.add(e1, Position(1, 1), Velocity(3, 4));
	assertTrue(registry.contains([e0, e1], Position(1, 1), Velocity(3, 4)));
	assertFalse(registry.contains([e0, e1, registry.entityNull], Position(1, 1), Velocity(3, 4)));

	registry.discard(e0);
	assertFalse(registry.contains!(Position, Velocity)(e0));
	assertFalse(registry.pools[componentId!Position].pool.contains(e0));
}


@safe pure
@("registry: containsAny")
unittest
{
	import ecs.component : componentId;
	auto registry = new Registry();
	auto e0 = registry.create();
	auto e1 = registry.create();

	registry.add!Position(e0, 1, 1);
	assertTrue(registry.containsAny!(Position, Velocity)(e0));

	registry.add!Velocity(e0, 3, 4);
	assertTrue(registry.containsAny!(Position, Velocity)(e0));

	registry.add(e1, Position(1, 1), Velocity(3, 4));
	assertTrue(registry.containsAny([e0, e1], Position(1, 1), Velocity(3, 4)));
	assertFalse(registry.containsAny([e0, e1, registry.entityNull], Position(1, 1), Velocity(3, 4)));

	registry.discard(e0);
	assertFalse(registry.containsAny!(Position, Velocity)(e0));
	assertFalse(registry.pools[componentId!Position].pool.contains(e0));
}


@safe pure
@("registry: create")
unittest
{
	auto registry = new Registry();
	auto entities = registry.create(3);

	assertEquals([0, 1, 2], entities);

	registry.discard(entities[0]);

	entities = registry.create(2);

	assertEquals([1 << 20, 3], entities);
}


@safe pure
@("registry: currentBatchOf")
unittest
{
	auto registry = new Registry();
	auto e0 = registry.create();
	assertEquals(0, registry.currentBatchOf(e0));

	registry.discard(e0);
	assertEquals(1, registry.currentBatchOf(e0));
}


@safe pure
@("registry: discard")
unittest
{
	auto registry = new Registry();
	const uint invalid = 1;
	auto exception = expectThrows!InvalidEntityException(registry.discard(invalid));
	assertEquals("Cannot discard entity with invalid id!", exception.msg);

	auto e0 = registry.create();
	registry.discard(e0);
	exception = expectThrows!InvalidEntityException(registry.discard(e0));
	assertEquals("Cannot discard entity with invalid id!", exception.msg);
}


@safe pure
@("registry: entities")
unittest
{
	import std.array : array;
	auto registry = new Registry();

	auto e0 = registry.create();
	auto e1 = registry.create();
	auto e2 = registry.create();

	assertEquals([e0, e1, e2], registry.entities.array);

	registry.discard(e1);
	const pos1 = registry.idOf(registry.entityNull) | (registry.currentBatchOf(e1) << registry.entityShift);
	assertEquals([e0, pos1, e2], registry.entities.array);

	registry.discard(e0);
	const pos0 = registry.idOf(e1) | (registry.currentBatchOf(e0) << registry.entityShift);
	assertEquals([pos0, pos1, e2], registry.entities.array);

	auto e01 = registry.create();
	auto e11 = registry.create();
	assertEquals([e01, e11, e2], registry.entities.array);
}


@safe pure
@("registry: get")
unittest
{
	import std.typecons : Tuple;

	auto registry = new Registry64();
	auto e0 = registry.create();
	auto e1 = registry.create();

	auto exceptionIE = expectThrows!InvalidEntityException(registry.get!Position(registry.entityNull));
	assertEquals("Cannot get a component from an invalid entity!", exceptionIE.msg);

	auto exceptionPDNE = expectThrows!PoolDoesNotExistException(registry.get!Position(e0));
	assertEquals("Cannot get a component from a non existent Pool!", exceptionPDNE.msg);

	registry.add!Position(e0, 5, 5);

	auto exceptionENIP = expectThrows!EntityNotInPoolException(registry.get!Position(e1));
	assertEquals("Cannot get a component from an entity which does not contain it!", exceptionENIP.msg);

	registry.add!Position(e1, 1, 1);

	Position* position0 = registry.get!Position(e0);
	Position* position1 = registry.get!Position(e1);

	assertSame(position0, registry.get!Position(e0));
	assertNotSame(position0, position1);

	position0.x = 50;
	assertTrue(50 == registry.get!Position(e0).x);

	registry.add!Colision(e0);
	Tuple!(Position*, Colision*) pc = registry.get!(Position, Colision)(e0);

	assertSame(pc[0], position0);
}


@safe pure
@("registry: hasSpawned")
unittest
{
	auto registry = new Registry();

	auto invalid = 0;
	assertFalse(registry.hasSpawned(invalid));

	auto e0 = registry.create();
	assertTrue(registry.hasSpawned(e0));

	registry.discard(e0);
	assertTrue(registry.hasSpawned(e0));
}


@safe pure
@("registry: idOf")
unittest
{
	auto registry = new Registry();

	auto e0 = registry.create();
	assertEquals(0, registry.idOf(e0));

	registry.discard(e0);
	assertEquals(0, registry.idOf(e0));

	auto e01 = registry.create();
	assertEquals(registry.idOf(e01), registry.idOf(e0));
	assertNotSame(e0, e01);
}


@safe pure
@("registry: isValid")
unittest
{
	auto registry = new Registry();

	auto invalid = 0;
	assertFalse(registry.isValid(invalid));

	auto e0 = registry.create();
	assertTrue(registry.isValid(e0));

	registry.discard(e0);
	assertFalse(registry.isValid(e0));

	auto e01 = registry.create();
	assertTrue(registry.isValid(e01));
	assertFalse(registry.isValid(e0));
}


@safe pure
@("registry: modify")
unittest
{
	auto registry = new Registry();
	auto e0 = registry.create();
	auto e1 = registry.create();

	auto exceptionIE = expectThrows!InvalidEntityException(registry.modify!Position(registry.entityNull, 0, 0));
	assertEquals("Cannot modify a component from an invalid entity!", exceptionIE.msg);

	auto exceptionPDNE = expectThrows!PoolDoesNotExistException(registry.modify!Position(e0, 0, 0));
	assertEquals("Cannot modify a component from a non existent Pool!", exceptionPDNE.msg);

	registry.add!Position(e0, 3, 3);
	registry.modify(e0, Position(17, 15));

	assertTrue(Position(17, 15) == *registry.get!Position(e0));

	registry.modify!Position(e0, 5, 7);

	assertFalse(__traits(compiles, registry.modify!Position(e0, 5, "not a field")));

	assertTrue(Position(5, 7) == *registry.get!Position(e0));

	auto exceptionENIP = expectThrows!EntityNotInPoolException(registry.modify!Position(e1, 5, 7));
	assertEquals("Cannot modify a component from an entity which does not contain it!", exceptionENIP.msg);

	registry.add!Velocity(e0);
	registry.modify(e0, Position(15, 14), Velocity(6, 8));

	assertTrue(Position(15, 14) == *registry.get!Position(e0));
	assertTrue(Velocity(6, 8) == *registry.get!Velocity(e0));
}


@safe pure
@("registry: pools")
unittest
{
	import ecs.component : componentId;
	auto registry = new Registry16();
	auto e0 = registry.create();

	registry.add!Position(e0, 2, 3);

	assertEquals(1, registry.pools.length);
	assertTrue(componentId!Position in registry.pools);
	assertFalse(componentId!Velocity in registry.pools);

	registry.remove!Position(e0);
	assertEquals(1, registry.pools.length);
	assertTrue(componentId!Position in registry.pools);
}


@safe pure
@("registry: queue")
unittest
{
	auto registry = new Registry();
	assertSame(registry.entityNull, registry.queue);

	auto e0 = registry.create();
	auto e1 = registry.create();
	auto e2 = registry.create();

	registry.discard(e0);
	assertSame(e0, registry.queue);

	registry.discard(e2);
	assertSame(e2, registry.queue);

	registry.discard(e1);
	assertSame(e1, registry.queue);

	registry.create();
	assertSame(e2, registry.queue);

	registry.create();
	assertSame(e0, registry.queue);

	registry.create();
	assertSame(registry.entityNull, registry.queue);
}


@safe pure
@("registry: remove")
unittest
{
	auto registry = new Registry8();
	auto e0 = registry.create();
	auto e1 = registry.create();

	auto exceptionIE = expectThrows!InvalidEntityException(registry.remove!Position(registry.entityNull));
	assertEquals("Cannot remove a component from an invalid entity!", exceptionIE.msg);

	auto exceptionPDNE = expectThrows!PoolDoesNotExistException(registry.remove!Position(e0));
	assertEquals("Cannot remove a component from a non existent Pool!", exceptionPDNE.msg);

	registry.add!Position(e0, 2, 3);
	registry.remove!Position(e0);

	auto exceptionENIP = expectThrows!EntityNotInPoolException(registry.remove!Position(e1));
	assertEquals("Cannot remove a component from an entity which does not contain it!", exceptionENIP.msg);

	expectThrows!EntityNotInPoolException(registry.remove!Position(e0));

	registry.add!(Position, Velocity, Colision)([e0, e1]);
	registry.remove!(Position)([e0, e1]);

	assertFalse(registry.contains!Position(e0));
	assertFalse(registry.contains!Position(e1));

	registry.remove!(Velocity, Colision)([e0, e1]);
	assertFalse(registry.contains!(Velocity, Colision)(e0));
	assertFalse(registry.contains!(Velocity, Colision)(e1));
}


@safe pure
@("registry: removeAll")
unittest
{
	import ecs.component : componentId;
	auto registry = new Registry8();
	auto e0 = registry.create();

	registry.add!Position(e0, 2, 3);
	registry.add!Velocity(e0, 4, 4);
	registry.removeAll(e0);

	assertFalse(registry.contains!(Position, Velocity)(e0));

	auto exception = expectThrows!InvalidEntityException(registry.removeAll(registry.entityNull));
	assertEquals("Cannot remove components from an invalid entity!", exception.msg);

	auto entities = registry.create(3);
	registry.add!(Position, Velocity, Colision)(entities);
	registry.removeAll(entities);

	foreach (e; entities)
	{
		assertFalse(registry.contains!(Position)(e));
		assertFalse(registry.contains!(Velocity)(e));
		assertFalse(registry.contains!(Colision)(e));
	}
}


private template registryReviveUnittest(T, T amount)
{
	enum registryReviveUnittest = q{
		auto registry = new BasicRegistry!(}~T.stringof~","~amount.stringof~q{);

		auto e0 = registry.create();
		registry.discard(e0);
		auto e1 = registry.create();
		assertNotSame(e1, e0);

		registry.discard(e1);
		auto e2 = registry.create();
		assertSame(e0, e2);
	};
}


@safe pure
@("registry: revive (ubyte)")
unittest
{
	mixin(registryReviveUnittest!(ubyte, 7));
}


@safe pure
@("registry: revive (ushort)")
unittest
{
	mixin(registryReviveUnittest!(ushort, 15));
}


@safe pure
@("registry: revive (uint)")
unittest
{
	mixin(registryReviveUnittest!(uint, 31));
}


@safe pure
@("registry: revive (ulong)")
unittest
{
	mixin(registryReviveUnittest!(ulong, 63));
}


private template registrySpawnUnittest(T, T amount)
{
	enum registrySpawnUnittest = q{
		auto registry = new BasicRegistry!(}~T.stringof~","~amount.stringof~q{);
		registry.create();
		auto exception = expectThrows!MaximumEntitiesReachedException(registry.spawn);
		assertEquals("Maximum entities reached!", exception.msg);
	};
}


@safe pure
@("registry: spawn (ubyte)")
unittest
{
	mixin (registrySpawnUnittest!(ubyte, 1));
}


@safe pure
@("registry: spawn (ushort)")
unittest
{
	mixin (registrySpawnUnittest!(ushort, 1));
}


@safe pure
@("registry: spawn (uint)")
unittest
{
	mixin (registrySpawnUnittest!(uint, 1));
}


@safe pure
@("registry: spawn (ulong)")
unittest
{
	mixin (registrySpawnUnittest!(ulong, 1));
}


@safe pure
@("registry: instance types")
unittest
{
	import std.meta : AliasSeq;
	static foreach(t; AliasSeq!(ubyte, ushort, uint, ulong))
	{
		assertTrue(__traits(compiles, new BasicRegistry!(t, 1)));
		assertTrue(__traits(compiles, new BasicRegistry!(t, t.sizeof * 8 - 1)));

		assertFalse(__traits(compiles, new BasicRegistry!(t, 0)));
		assertFalse(__traits(compiles, new BasicRegistry!(t, t.sizeof * 8)));
	}

	struct Foo {}
	static foreach(t; AliasSeq!(byte, short, int, long, char, dchar, string, dstring, float, double, Foo))
	{
		assertFalse(__traits(compiles, new BasicRegistry!(t, 1)));
	}
}


@safe pure
@("registry: updateBatch")
unittest
{
	auto registry = new BasicRegistry!(ubyte, 7);

	auto e0 = registry.create();
	assertEquals(0, registry.batchOf(e0));

	// increments batch
	assertEquals(1, registry.updateBatch(e0));
	registry.discard(e0);
	auto e1 = registry.create();

	// maximum batch reached (1 bit), resets to 0!
	assertEquals(0, registry.updateBatch(e1));
}
